import SwiftUI
import MapKit
import Charts
import UniformTypeIdentifiers
import Compression

/// Flight log view showing all recorded flights
struct FlightLogView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @Environment(\.dismiss) var dismiss

    /// When presented as a custom overlay (HomeView's leading-edge slide-in), the host supplies a
    /// close action; otherwise `nil` and the standard `@Environment(\.dismiss)` is used. (v4 UI/UX Revamp)
    var onClose: (() -> Void)? = nil
    /// Optional flight to preselect in the iPad 2-column pane (e.g. the Home last-flight strip).
    /// It feeds `effectiveSelectionID` for the pane only — it never drives the compact push path,
    /// so it can't trigger the transient-geometry push race. Compact opens the detail directly from
    /// Home instead. (v4 UI/UX Revamp — feedback)
    var initialFlightID: UUID? = nil
    /// Which half this screen shows. The ground tabs split it: the Logbook tab is `.logbook`, the Plan
    /// tab's flights are `.plan`, both without a Close button. Presented on its own it stays
    /// `.combined`, with the Past / Upcoming picker. (v6.0 · P1)
    var mode: Mode = .combined

    enum Mode { case combined, logbook, plan }

    /// What the 2-column pane shows: a manual selection wins, otherwise the seeded initial flight.
    private var effectiveSelectionID: UUID? { selectedFlightID ?? initialFlightID }
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showImportError = false
    /// A flight just imported whose file had no name for it: the Logbook offers to name it, and an
    /// empty answer keeps the route as its only title. (v6.1)
    @State private var namingImport: ImportNaming?
    @State private var importedName = ""

    struct ImportNaming: Identifiable, Equatable {
        let id: UUID
        let spokenTitle: String
    }
    @State private var showExportAllSheet = false
    @State private var exportAllType: ExportAllType = .gpx
    /// The export bundle is built off the main actor (PERF-12); the share sheet presents only once
    /// `exportAllZipData` is ready. `isPreparingExportAll` drives a progress indicator meanwhile.
    @State private var exportAllZipData: Data?
    /// The AMC1 FCL.050 logbook extract, held until its share sheet is up. (v5.0.0)
    @State private var logbookPDFData: Data?
    @State private var showLogbookPDFSheet = false
    @State private var isPreparingExportAll = false
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Year scope for the dashboard + list (nil = all time). Defaults to the current year, like a logbook.
    /// UTC, to match `filteredFlights` — see the note there. (review F-logbook-7)
    static let logbookCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @State private var selectedYear: Int? = FlightLogView.logbookCalendar.component(.year, from: Date())
    /// True while a flight is being created, so a double-tap cannot make two. (review, concurrency)
    @State private var isCreatingFlight = false
    /// Optional aircraft filter (registration); nil = all aircraft.
    @State private var selectedAircraft: String? = nil
    /// Selected flight id — drives the iPad-landscape 2-column detail pane and the compact
    /// push (`navigationDestination`). A `UUID` (Hashable) avoids making `Flight` itself
    /// Hashable/Equatable, which would have to be id-only and break content-change detection. (v4 UI/UX Revamp)
    @State private var selectedFlightID: UUID? = nil
    /// Non-nil while the stats share-card customization sheet is open (snapshot of the current filter). (v4 UI/UX Revamp)
    @State private var statsShareData: StatsShareCardData? = nil
    /// Flights a swipe (or Edit-mode delete) has proposed removing, held until the pilot confirms.
    /// A logbook entry is the only record of a flight and deletion is irreversible, so the list must
    /// guard it exactly as the detail screen already does — a mis-swipe in turbulence must not be
    /// able to destroy an entry on its own.
    @State private var pendingDeletion: [Flight] = []
    /// Which half of a flight's life this screen shows. Upcoming and flown flights are the same
    /// object at different points in its life, so they share one destination rather than two rail
    /// items a pilot has to disambiguate. (v5.0.0)
    @State private var segment: FlightsSegment = .past
    /// The flight being planned — from the Upcoming empty state or "Plan this again". (v5.0.0)
    @State private var planningNewFlight: NewFlightIntent?
    /// The saved-routes list, reachable from Upcoming. (v5.x)
    @State private var showFlightPlanning = false
    @State private var threadToOpen: UUID?
    /// A day of two flights or more, shared as one card from its header. (6.1)
    @State private var journeyShare: JourneyShareRequest?

    enum FlightsSegment: String, CaseIterable {
        // Past first: it is the half with data in it, it is what this screen has always opened on,
        // and left-to-right reading puts what happened before what has not happened yet.
        case past, upcoming
        var label: String { self == .upcoming ? L10n.Flights.upcoming : L10n.Flights.past }
    }

    /// The two halves, side by side, so a pilot never has to know which one their flight is in.
    private var segmentPicker: some View {
        Picker("", selection: $segment.animation(.easeInOut(duration: 0.18))) {
            ForEach(FlightsSegment.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Everything this screen was before the merge: flown flights, their stats and their export.
    private var pastContent: some View {
        pastFlights
            .task { await repairMissingAerodromes() }
    }

    /// Flights saved without a departure or an arrival get theirs here, so the list reads by route.
    /// Airport data is lazy, and nothing else here needs it: it is loaded only when a flight not yet
    /// tried is waiting, and only when there is data on the device to load. (v6.1)
    private func repairMissingAerodromes() async {
        guard airportDataService.isDataAvailable, await appState.hasFlightsAwaitingAerodromes() else { return }
        await airportDataService.ensureLoaded()
        guard airportDataService.airportCount > 0 else { return }
        await appState.repairMissingAerodromes(nearestAerodrome: { airportDataService.aerodromeIdent(at: $0) })
    }

    @ViewBuilder
    private var pastFlights: some View {
                if appState.isLoadingFlights {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(Color.aviationGold)
                        Text(L10n.FlightLog.loading)
                            .font(.aero(.subheadline))
                            .foregroundColor(.secondaryText)
                    }
                } else if appState.flights.isEmpty {
                    emptyState
                } else {
                    GeometryReader { geo in
                        // Keyboard or not: the keyboard of a sheet over the Logbook ("Plan this
                        // again", or the name asked after an import) made this reader wider than tall
                        // in portrait, and the list behind it went to two columns. Not
                        // `.ignoresSafeArea(.keyboard)`: in two columns the detail's name and notes
                        // still need the keyboard's avoidance. (6.1.0)
                        if horizontalSizeClass == .regular,
                           KeyboardProofOrientation.isLandscape(size: geo.size, bottomInset: geo.safeAreaInsets.bottom) {
                            // iPad landscape: master (list) left + detail pane right, like the HUD. (v4 UI/UX Revamp)
                            HStack(spacing: 0) {
                                flightList(twoColumn: true)
                                    .frame(width: geo.size.width * 0.42)
                                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                                detailColumn
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            flightList(twoColumn: false)
                                .navigationDestination(item: $selectedFlightID) { id in
                                    if let flight = appState.flights.first(where: { $0.id == id }) {
                                        FlightDetailView(flight: flight).id(flight.id)
                                    }
                                }
                        }
                    }
                }
    }


    enum ExportAllType: Sendable {
        case gpx
        case json
    }

    /// Per-aircraft accent palette for the hours-by-aircraft bars.
    private static let aircraftPalette: [Color] = [.aviationGold, .altimeterBlue, .aviationGreen, .aviationAmber, .orange]
    
    /// In the Plan tab, the tab's own navigation stack holds this list. A second stack inside it put
    /// its bar in the tab bar's row and dragged the Plan picker up under the tabs. (on-device review
    /// #1, G-07)
    @ViewBuilder
    private var navigationContainer: some View {
        if mode == .plan {
            listContent
        } else {
            NavigationStack { listContent }
        }
    }

    private var listContent: some View {
        ZStack {
            Color.cockpitBackground
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                if mode == .combined { segmentPicker }
                if mode == .plan || (mode == .combined && segment == .upcoming) {
                    UpcomingFlightsList(threads: threadManager.unfinishedThreads,
                                        trips: threadManager.trips,
                                        allThreads: threadManager.threads,
                                        onOpen: { threadToOpen = $0 },
                                        onPlanNew: { planningNewFlight = seedIntent() },
                                        // The Plan tab has its own Routes segment, one tap away.
                                        onOpenRoutes: mode == .plan ? nil : { showFlightPlanning = true })
                } else {
                    pastContent
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Close + import only — the big in-content "Flight Log" title and the gold Export
            // button live in the dashboard header now (concept). (v4 UI/UX Revamp)
            if mode == .combined {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.FlightLog.close) { if let onClose { onClose() } else { dismiss() } }
                }
            }
            if mode != .plan {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showImportPicker = true }) {
                        Label(L10n.FlightLog.importFlights, systemImage: "square.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }

    var body: some View {
        navigationContainer
        // Only as its own cover. Embedded in a ground tab, a preferred scheme would darken the whole
        // window, and the root could no longer read the device's light/dark for Auto. (v6.0 · P1)
        .preferredColorScheme(mode == .combined ? .dark : nil)
        .fullScreenCover(isPresented: $showFlightPlanning) {
            FlightPlanningView()
        }
        .sheet(isPresented: $showExportAllSheet) {
            if let zipData = exportAllZipData {
                let filename = "AeroCheck_\(formattedExportDate)_ExportBundle.zip"
                ShareSheet(activityItems: [
                    ShareFile(data: zipData, filename: filename, dataTypeIdentifier: "public.zip-archive")
                ])
            }
        }
        .sheet(item: $statsShareData) { data in
            StatsShareCardCustomizationView(data: data, appState: appState)
        }
        .sheet(item: $journeyShare) { request in
            JourneyShareCustomizationView(flights: request.flights, appState: appState,
                                          airports: airportDataService, title: request.title)
        }
        .fullScreenCover(isPresented: Binding(
            get: { threadToOpen != nil },
            set: { if !$0 { threadToOpen = nil } }
        )) {
            if let id = threadToOpen {
                // Started through the root, which has the launch: a flight opened here had no START
                // FLIGHT at all. (round 6)
                FlightThreadView(threadId: id, onClose: { threadToOpen = nil },
                                 onStartFlight: { circuits in
                                     threadToOpen = nil
                                     appState.pendingFlightStart = PendingFlightStart(threadId: id, circuits: circuits)
                                 },
                                 onOpenLeg: { threadToOpen = $0 })
                    .environmentObject(threadManager)
                    .environmentObject(flightPlanManager)
            }
        }
        .sheet(isPresented: Binding(
            get: { planningNewFlight != nil },
            set: { if !$0 { planningNewFlight = nil } }
        )) {
            if let seed = planningNewFlight {
                PlanNewFlightView(
                    intent: seed,
                    // The pilot's aircraft as chips here too: this sheet used to offer none from
                    // the Flights tab, so a flight planned there took whatever Today had selected.
                    aircraft: AircraftOption.flyable(remote: aircraftDataService.availableAircraft,
                                                     settings: appState.settings,
                                                     canFly: aircraftDataService.canFly),
                    savedRoutes: RouteLibrary.activeRoutes(flightPlanManager.flightPlans, threads: threadManager.threads),
                    homeAerodrome: appState.settings.homeAerodromeIdent,
                    onCreate: { planned in
                        planningNewFlight = nil
                        // See HomeView.createFlight: the sheet stays hit-testable through its
                        // dismissal, and the creation suspends — so a double-tap made two flights.
                        // (review, concurrency)
                        guard !isCreatingFlight else { return }
                        isCreatingFlight = true
                        Task { @MainActor in
                            defer { isCreatingFlight = false }
                            segment = .upcoming
                            threadToOpen = await FlightCreator.create(planned, plans: flightPlanManager,
                                                                      threads: threadManager,
                                                                      airports: airportDataService)
                        }
                    },
                    onCancel: { planningNewFlight = nil }
                )
            }
        }
        .sheet(isPresented: $showLogbookPDFSheet) {
            if let pdf = logbookPDFData {
                ShareSheet(activityItems: [
                    ShareFile(data: pdf,
                              filename: "AeroCheck_\(formattedExportDate)_Logbook.pdf",
                              dataTypeIdentifier: "com.adobe.pdf")
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
        .alert(L10n.FlightLog.nameImportedTitle,
               isPresented: Binding(get: { namingImport != nil }, set: { if !$0 { namingImport = nil } }),
               presenting: namingImport) { naming in
            TextField(L10n.FlightDetail.namePlaceholder, text: $importedName)
            Button(L10n.FlightLog.nameImportedSave) { nameImportedFlight(naming.id) }
            Button(L10n.FlightLog.nameImportedSkip, role: .cancel) { }
        } message: { naming in
            // The spoken form, "LSZQ to LSGE": it reads as well as it sounds.
            Text(L10n.FlightLog.nameImportedMessage(naming.spokenTitle))
        }
    }
    
    private var formattedExportDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }
    
    /// Serialize every flight and zip them off the main actor, then present the share sheet.
    /// Keeps the heavy serialize/CRC/zip work out of the `.sheet` content builder. (PERF-12)
    private func prepareExportAll(_ flights: [Flight]) {
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

    /// Render the logbook extract off the main actor and present its share sheet. Same shape as
    /// `prepareExportAll` and for the same reason: a hundred flights is a lot of PDF drawing, and
    /// none of it belongs in a `.sheet` content builder. (v5.0.0)
    private func prepareLogbookPDF(_ flights: [Flight]) {
        let pilotName = appState.settings.pilotName
        let pilotContext = appState.settings.logbookPilotContext
        isPreparingExportAll = true
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) {
                LogbookPDFExportService.export(flights: flights,
                                               options: .init(pilotName: pilotName, pilot: pilotContext))
            }.value
            logbookPDFData = data
            isPreparingExportAll = false
            showLogbookPDFSheet = (data != nil)
        }
    }

    /// A blank intent carrying the aircraft the pilot last flew, which is a better guess than an
    /// empty field and costs nothing to change. (v5.0.0)
    private func seedIntent() -> NewFlightIntent {
        let recent = appState.flights.first
        return NewFlightIntent(
            departureIdent: "",
            arrivalIdent: "",
            departureTime: nil,
            aircraftTypeId: recent?.flightPlan?.aircraftTypeId ?? appState.settings.selectedAircraft.rawValue,
            aircraftRegistration: recent?.aircraftRegistration ?? appState.settings.selectedAircraft.registration,
            aircraftModelName: recent?.aircraftType ?? appState.settings.selectedAircraft.modelName,
            kind: .crossCountry
        )
    }

    /// "Plan this again" — opens the SAME creation sheet, pre-filled. Deliberately not a second,
    /// quieter way to create a flight: `NewFlightIntent` carries the route, the aircraft and the kind
    /// and has nowhere to put a ticked task, so last week's preparation cannot come with it. (v5.0.0)
    private func planAgain(_ flight: Flight) {
        planningNewFlight = NewFlightIntent(duplicating: flight)
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
                .scaledFont(size: 80, relativeTo: .largeTitle)
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

    /// Sorted flights scoped to the selected year + aircraft (drives the dashboard stats and the list).
    private var filteredFlights: [Flight] {
        // Read from `body` in eight places per pass (dashboard stats twice, favourites, month groups,
        // the empty check, the export menu) and each read re-ran a full sort plus a per-flight
        // `Calendar.current.component` lookup over the whole logbook. (APP-08)
        //
        // The unfiltered case — no year and no aircraft selected, which is how the screen opens — is
        // now returned directly, skipping N closure invocations and N calendar lookups per read for
        // a filter that would have kept every flight anyway. When a filter IS active, `Calendar` is
        // resolved once instead of once per flight per read.
        //
        // Deliberately NOT converted into a compute-once-and-thread-down parameter: that means
        // reshaping six call sites across a 4500-line view for a ground screen, and the sort itself
        // is the remaining cost either way. Revisit if the logbook screen ever shows up in a trace.
        guard selectedYear != nil || selectedAircraft != nil else { return sortedFlights }

        // UTC, matching every date the logbook PRINTS. Scoping by the local calendar year while the
        // pages are dated in UTC put a flight blocking off 1 Jan 00:30 CET (31 Dec 23:30 UTC) in the
        // 2027 extract, printed as "31.12.2026" — a page contradicting its own scope, and both
        // years' totals out by one flight. (review F-logbook-7)
        let calendar = FlightLogView.logbookCalendar
        return sortedFlights.filter { flight in
            let yearOK: Bool = {
                guard let year = selectedYear else { return true }
                guard let start = flight.startTime else { return false }
                return calendar.component(.year, from: start) == year
            }()
            let aircraftOK = selectedAircraft == nil || (flight.aircraftRegistration ?? flight.airplane) == selectedAircraft
            return yearOK && aircraftOK
        }
    }

    /// Distinct years present in the log, most recent first.
    private var availableYears: [Int] {
        Set(appState.flights.compactMap {
            $0.startTime.map { FlightLogView.logbookCalendar.component(.year, from: $0) }
        }).sorted(by: >)
    }

    /// Distinct aircraft (registration) present in the log, in recency order.
    private var availableAircraft: [String] {
        var seen: [String] = []
        for flight in sortedFlights {
            let key = flight.aircraftRegistration ?? flight.airplane
            if !seen.contains(key) { seen.append(key) }
        }
        return seen
    }

    private static func groupedNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? value.safeRoundedInt().map(String.init) ?? "—"
    }

    /// The right-hand detail pane in the 2-column layout (or a placeholder until a flight is picked).
    @ViewBuilder
    private var detailColumn: some View {
        if let id = effectiveSelectionID, let selected = appState.flights.first(where: { $0.id == id }) {
            FlightDetailView(flight: selected)
                .id(selected.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "airplane.circle")
                    .scaledFont(size: 48, relativeTo: .largeTitle)
                    .foregroundColor(.dimText)
                Text("Select a flight")
                    .scaledFont(size: 16, relativeTo: .body)
                    .foregroundColor(.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cockpitBackground)
        }
    }

    private func flightList(twoColumn: Bool) -> some View {
        List {
            Section {
                dashboardHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }

            if filteredFlights.isEmpty {
                Section {
                    Text("No flights in this period")
                        .scaledFont(size: 14, relativeTo: .subheadline)
                        .foregroundColor(.dimText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                // Pinned favorites float above the month pages. (v4 UI/UX Revamp favorites)
                let favorites = favoriteFlights
                if !favorites.isEmpty {
                    Section {
                        ForEach(favorites) { flight in
                            flightRow(flight, twoColumn: twoColumn)
                        }
                        .onDelete { offsets in stageDeletion(favorites, at: offsets) }
                    } header: {
                        favoritesHeader(count: favorites.count)
                    }
                }

                // Grouped into logbook "pages" by month, newest first. (round 7, option B)
                // Within a month, a day of two flights or more opens on its header, with its totals
                // and "Share day"; a day of one flight reads as it always did. The header counts and
                // shares the whole day in the filter, favourites included. (6.1)
                let days = Dictionary(LogbookDay.days(filteredFlights).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(monthGroups) { group in
                    Section {
                        ForEach(group.days) { day in
                            if let whole = days[day.id], whole.hasHeader {
                                LogbookDayHeader(day: whole, nauticalMiles: appState.settings.distanceInNauticalMiles) {
                                    journeyShare = JourneyShareRequest(flights: whole.flights, title: L10n.ShareCard.shareDay)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 4, trailing: 12))
                            }
                            ForEach(day.flights) { flight in
                                flightRow(flight, twoColumn: twoColumn)
                            }
                            .onDelete { offsets in stageDeletion(day.flights, at: offsets) }
                        }
                        ForEach(group.undated) { flight in
                            flightRow(flight, twoColumn: twoColumn)
                        }
                        .onDelete { offsets in stageDeletion(group.undated, at: offsets) }
                    } header: {
                        monthHeader(group)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .alert(L10n.FlightDetail.deleteTitle, isPresented: deleteConfirmationPresented) {
            Button(L10n.Button.cancel, role: .cancel) { pendingDeletion = [] }
            Button(L10n.Button.delete, role: .destructive) {
                for flight in pendingDeletion { appState.deleteFlight(flight) }
                pendingDeletion = []
            }
        } message: {
            Text(L10n.FlightDetail.deleteMessage)
        }
    }

    /// Drives the delete alert off `pendingDeletion` so a dismissal by any route (Cancel, tapping
    /// away, the swipe being undone) clears the staged flights rather than leaving them armed.
    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { presented in if !presented { pendingDeletion = [] } }
        )
    }

    @ViewBuilder
    private func flightRow(_ flight: Flight, twoColumn: Bool) -> some View {
        if twoColumn {
            // 2-column: tap selects the right-pane detail (no push).
            Button { selectedFlightID = flight.id } label: {
                FlightRowView(flight: flight, nauticalMiles: appState.settings.distanceInNauticalMiles)
                    // `.buttonStyle(.plain)` hit-tests the label's RENDERED content, so the gaps and
                    // Spacer regions between the row's text and its trailing glance were dead space —
                    // only the text itself opened the flight. Make the whole row rect tappable.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(effectiveSelectionID == flight.id ? Color.aviationGold.opacity(0.12) : Color.cardBackground)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                favoriteSwipeButton(flight)
                planAgainSwipeButton(flight)
            }
        } else {
            // Compact: same selection state drives a push via navigationDestination(item:), so the
            // Home last-flight strip can open straight onto a flight's detail. (v4 UI/UX Revamp)
            Button { selectedFlightID = flight.id } label: {
                FlightRowView(flight: flight, nauticalMiles: appState.settings.distanceInNauticalMiles)
                    .contentShape(Rectangle())   // whole row tappable, not just the text
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.cardBackground)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                favoriteSwipeButton(flight)
                planAgainSwipeButton(flight)
            }
        }
    }

    /// "Plan this again" — the cheapest route to next Saturday's flight when it is last Saturday's
    /// flight again. Second in the leading swipe so the full-swipe gesture still favourites, which is
    /// what it has always done. (v5.0.0)
    private func planAgainSwipeButton(_ flight: Flight) -> some View {
        Button { planAgain(flight) } label: {
            Label(L10n.Flights.planThisAgain, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .tint(.altimeterBlue)
    }

    /// Leading (swipe-right) favorite toggle. Trailing swipe stays the iOS-conventional delete. (v4 UI/UX Revamp)
    private func favoriteSwipeButton(_ flight: Flight) -> some View {
        Button {
            withAnimation { appState.toggleFavorite(flight) }
        } label: {
            Label(flight.isFavorite ? "Unfavorite" : "Favorite",
                  systemImage: flight.isFavorite ? "star.slash.fill" : "star.fill")
        }
        .tint(.aviationGold)
    }

    /// Favorited flights within the current filter, newest first (pinned above the month pages). (v4 UI/UX Revamp)
    private var favoriteFlights: [Flight] {
        filteredFlights.filter { $0.isFavorite }
    }

    private func favoritesHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill").scaledFont(size: 11, relativeTo: .caption2).foregroundColor(.aviationGold)
            Text("FAVORITES")
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .tracking(0.6)
                .foregroundColor(.aviationGold)
            Spacer()
            Text("\(count)")
                .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(.secondaryText)
        }
        .textCase(nil)
    }

    private func monthHeader(_ group: MonthGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.label)
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .tracking(0.6)
                .foregroundColor(.aviationGold)
            Spacer()
            Text("\(group.flights.count) flight\(group.flights.count == 1 ? "" : "s") · \(String(format: "%.1f", group.totalHours)) h")
                .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(.secondaryText)
        }
        .textCase(nil)
    }

    private struct MonthGroup: Identifiable {
        let id: String
        let label: String
        let flights: [Flight]
        let totalHours: Double

        /// The month's flights by day, newest first; flights without a date in `undated`. (6.1)
        var days: [LogbookDay] { LogbookDay.days(flights) }
        var undated: [Flight] { flights.filter { $0.startTime == nil } }
    }

    /// `filteredFlights` grouped by month (newest first; flights already sorted newest-first).
    /// Favorites are excluded — they live in their own pinned section so they aren't shown twice. (round 7 / 3.3)
    private var monthGroups: [MonthGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Flight]] = [:]
        for flight in filteredFlights where !flight.isFavorite {
            let key: String
            if let date = flight.startTime {
                let comps = calendar.dateComponents([.year, .month], from: date)
                key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            } else {
                key = "0000-00"
            }
            if buckets[key] == nil { buckets[key] = []; order.append(key) }
            buckets[key]?.append(flight)
        }
        return order.map { key in
            let flights = buckets[key] ?? []
            let hours = flights.reduce(0.0) { $0 + ($1.loggedSeconds / 3600) }
            let label: String
            if key == "0000-00" {
                label = "UNDATED"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM yyyy"
                label = (flights.first?.startTime).map { formatter.string(from: $0).uppercased() } ?? key
            }
            return MonthGroup(id: key, label: label, flights: flights, totalHours: hours)
        }
    }

    /// Sticky bottom bar so export-all is always reachable without scrolling past every flight. Exports
    /// ALL flights (the header's Export button handles the filtered/listed subset). (round 7)
    /// Stage swiped flights for deletion. Deliberately does NOT delete: it only records what was
    /// swiped so `deleteConfirmation` can ask first. Resolving the offsets to `Flight` values here
    /// (rather than keeping indices) means the confirmation deletes exactly what was swiped even if
    /// the list re-sorts or re-groups while the alert is up.
    private func stageDeletion(_ flights: [Flight], at offsets: IndexSet) {
        pendingDeletion = offsets.compactMap { flights.indices.contains($0) ? flights[$0] : nil }
    }

    // MARK: - Dashboard (v4 UI/UX Revamp Flight Log revamp)

    private var dashboardHeader: some View {
        let stats = aggregateStats(filteredFlights)
        return VStack(spacing: 14) {
            // Title + year selector + export (concept header)
            HStack(alignment: .center) {
                // The tab's name: flown flights live in the Logbook. (v6.0 · P8)
                Text(L10n.Ground.logbook)
                    .scaledFont(size: 28, weight: .bold, relativeTo: .title2)
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                yearMenu
                shareCardButton
                exportMenu
            }

            // Metric cards — 4 across on regular width, 2 on compact.
            LazyVGrid(columns: metricColumns, spacing: 10) {
                LogMetricCard(label: "Hours", value: String(format: "%.1f", stats.totalHours), valueColor: .aviationGold)
                LogMetricCard(label: "Flights", value: "\(stats.flights)")
                LogMetricCard(label: "Landings", value: "\(stats.landings)")
                // Tap the distance card to toggle NM ⇄ km (persisted; also affects the list rows).
                Button { toggleDistanceUnit() } label: {
                    LogMetricCard(label: distanceUnitLabel, value: Self.groupedNumber(distanceValue(stats.distanceKm)))
                }
                .buttonStyle(.plain)
            }

            if stats.byAircraft.count > 1 {
                hoursByAircraft(stats.byAircraft)
            }

            spendRow

            // List header: count + aircraft filter.
            HStack {
                Text("\(stats.flights) FLIGHTS")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .tracking(0.5)
                    .foregroundColor(.secondaryText)
                Spacer()
                filterMenu
            }
            .padding(.top, 2)
        }
    }

    /// Spend for the selected period, shown only once at least one flight has a cost recorded.
    ///
    /// It always says how many flights have NOTHING recorded, because a total built from three of
    /// forty flights is not a period total and a bare sum invites reading it as one. (v5.0.0)
    @ViewBuilder
    private var spendRow: some View {
        let summary = CostLedger.summarize(flights: filteredFlights, rates: appState.settings.aircraftRates)
        if summary.flightsWithCost > 0 {
            HStack(spacing: 10) {
                Text(L10n.Cost.ledgerTitle.uppercased())
                    .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                    .tracking(0.5)
                    .foregroundColor(.dimText)
                Text(FlightCostCalculator.formatAmount(summary.total, currency: summary.currency))
                    .scaledFont(size: 16, weight: .bold, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)
                Spacer(minLength: 6)
                if summary.flightsMissingCost > 0 {
                    Text(L10n.Cost.missingCost(summary.flightsMissingCost))
                        .scaledFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.aviationAmber.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.aviationGold.opacity(0.22), lineWidth: 1))
            )
        }
    }

    private var metricColumns: [GridItem] {
        let count = horizontalSizeClass == .compact ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    // Distance unit (persisted) — toggled by tapping the distance card. (round 7)
    private var distanceUnitLabel: String { appState.settings.distanceInNauticalMiles ? "NM" : "km" }
    private func distanceValue(_ km: Double) -> Double { appState.settings.distanceInNauticalMiles ? km * 0.539957 : km }
    private func toggleDistanceUnit() {
        appState.settings.distanceInNauticalMiles.toggle()
        appState.saveSettings()
    }

    /// Label describing the share-card scope, e.g. "F-HVXA · 2026" or "All time". (round 7)
    private var shareScopeLabel: String {
        var parts: [String] = []
        if let aircraft = selectedAircraft { parts.append(aircraft) }
        parts.append(selectedYear.map { String($0) } ?? String(localized: "All time"))
        return parts.joined(separator: " · ")
    }

    /// Snapshot the currently-filtered stats and open the customization sheet. The sheet owns the
    /// theme/accent/layout choices, live preview, and the final render+share. (round 10)
    private func openStatsShareSheet() {
        let stats = aggregateStats(filteredFlights)
        let slices = stats.byAircraft.enumerated().map { index, item in
            StatsShareCardData.AircraftSlice(
                name: item.name,
                hours: item.hours,
                color: Self.aircraftPalette[index % Self.aircraftPalette.count]
            )
        }
        statsShareData = StatsShareCardData(
            periodLabel: shareScopeLabel,
            hours: stats.totalHours,
            flights: stats.flights,
            landings: stats.landings,
            distance: distanceValue(stats.distanceKm),
            unit: distanceUnitLabel,
            byAircraft: slices
        )
    }

    private var yearMenu: some View {
        Menu {
            Picker("Year", selection: $selectedYear) {
                Text("All time").tag(Int?.none)
                ForEach(availableYears, id: \.self) { year in
                    Text(verbatim: "\(year)").tag(Int?.some(year))
                }
            }
        } label: {
            HStack(spacing: 4) {
                // verbatim + String() so the year never gets a thousands separator ("2'026"). (round 7)
                Text(verbatim: selectedYear.map { String($0) } ?? "All")
                    .scaledFont(size: 15, weight: .medium, relativeTo: .subheadline)
                Image(systemName: "chevron.down").scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
            }
            .foregroundColor(.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            )
        }
    }

    /// One Export entry: scope (listed/all) × format (GPX/JSON). Each downloads a .zip bundle of that
    /// format, so there's no separate "ZIP" option and no second export affordance. (round 8)
    private var exportMenu: some View {
        Menu {
            Section("Listed (\(filteredFlights.count))") {
                Button("GPX") { exportAllType = .gpx; prepareExportAll(filteredFlights) }
                Button("JSON") { exportAllType = .json; prepareExportAll(filteredFlights) }
            }
            Section("All flights (\(appState.flights.count))") {
                Button("GPX") { exportAllType = .gpx; prepareExportAll(appState.flights) }
                Button("JSON") { exportAllType = .json; prepareExportAll(appState.flights) }
            }
            // The logbook extract is a single PDF rather than a bundle of tracks, so it gets its own
            // section instead of a third format alongside GPX and JSON.
            Section(L10n.Logbook.subtitle) {
                Button(L10n.Logbook.exportPDF) { prepareLogbookPDF(filteredFlights) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up").scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                Text("Export").scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationGold))
        }
        .accessibilityLabel("Export")
    }

    /// Secondary action: open the stats-summary share-card customization sheet for the current filter. (round 10)
    private var shareCardButton: some View {
        Button { openStatsShareSheet() } label: {
            Image(systemName: "photo")
                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                .foregroundColor(.black)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationGold))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share stats card")
    }

    private var filterMenu: some View {
        Menu {
            Picker(L10n.Settings.aircraft, selection: $selectedAircraft) {
                Text("All aircraft").tag(String?.none)
                ForEach(availableAircraft, id: \.self) { aircraft in
                    Text(aircraft).tag(String?.some(aircraft))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedAircraft == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .scaledFont(size: 13, relativeTo: .caption)
                Text(selectedAircraft ?? "Filter").scaledFont(size: 13, weight: .medium, relativeTo: .caption)
            }
            .foregroundColor(selectedAircraft == nil ? .secondaryText : .aviationGold)
        }
    }

    private func hoursByAircraft(_ items: [(name: String, hours: Double)]) -> some View {
        let maxHours = items.map(\.hours).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("HOURS BY AIRCRAFT")
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .tracking(0.6)
                .foregroundColor(.secondaryText)
            ForEach(Array(items.enumerated()), id: \.element.name) { index, item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                        .frame(width: 76, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06))
                            Capsule().fill(Self.aircraftPalette[index % Self.aircraftPalette.count])
                                .frame(width: max(4, geo.size.width * CGFloat(item.hours / max(maxHours, 0.01))))
                        }
                    }
                    .frame(height: 7)
                    Text(String(format: "%.1f", item.hours))
                        .scaledFont(size: 13, weight: .semibold, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.primaryText)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private struct LogStats {
        var flights: Int
        var totalHours: Double
        var landings: Int
        var distanceKm: Double
        var byAircraft: [(name: String, hours: Double)]
    }

    /// Aggregate logbook stats over the given flights. Hours prefer block time, then flight time, then
    /// the engine-start→shutdown duration. (v4 UI/UX Revamp)
    private func aggregateStats(_ flights: [Flight]) -> LogStats {
        var totalSeconds = 0.0
        var landings = 0
        var distance = 0.0
        var perAircraft: [String: Double] = [:]
        for flight in flights {
            let seconds = flight.loggedSeconds
            totalSeconds += seconds
            landings += flight.totalLandings
            distance += flight.distanceKilometers
            let key = flight.aircraftRegistration ?? flight.airplane
            perAircraft[key, default: 0] += seconds
        }
        let byAircraft = perAircraft
            .map { (name: $0.key, hours: $0.value / 3600) }
            .sorted { $0.hours > $1.hours }
        return LogStats(
            flights: flights.count,
            totalHours: totalSeconds / 3600,
            landings: landings,
            distanceKm: distance,
            byAircraft: byAircraft
        )
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
                // SEC-C31: cap the file BEFORE reading it into memory. The ZIP branch has
                // enforced per-entry and total budgets since SA-24, but a directly-picked .json/.gpx
                // was loaded whole with no bound at all.
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize <= FlightDataLimits.maxImportEntryBytes else {
                    importError = L10n.ImportLimits.tooLarge
                    showImportError = true
                    return
                }

                let data = try Data(contentsOf: url)

                // Check if it's a ZIP file
                if url.pathExtension.lowercased() == "zip" {
                    // An archive is a batch: its flights keep what their files say, unasked.
                    handleZipImport(data: data)
                } else if let imported = appState.importedFlight(from: data) {
                    Task { await placeAndOfferName(imported.flight.id, suggestion: imported.suggestedName) }
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

    /// After a single import: find the flight's aerodromes (a file from another app has none), then,
    /// when the file had no name for it, offer one, never require it. A GPX from another app offers
    /// its own track name. (v6.1)
    private func placeAndOfferName(_ id: UUID, suggestion: String?) async {
        await repairMissingAerodromes()
        guard let flight = appState.flights.first(where: { $0.id == id }),
              Flight.nonBlank(flight.name) == nil else { return }
        importedName = suggestion ?? ""
        namingImport = ImportNaming(id: id, spokenTitle: flight.spokenTitle)
    }

    /// The name typed after an import; empty keeps the route alone.
    private func nameImportedFlight(_ id: UUID) {
        guard let name = Flight.nonBlank(importedName),
              let flight = appState.flights.first(where: { $0.id == id }) else { return }
        appState.updateFlightName(flight, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handleZipImport(data: Data) {
        do {
            let entries = try Self.extractZipEntries(from: data)
            var successCount = 0
            var failCount = 0

            for entry in entries {
                if appState.importFlight(from: entry.data) {
                    successCount += 1
                } else {
                    failCount += 1
                }
            }

            if successCount > 0 {
                Task { await repairMissingAerodromes() }   // files from other apps carry no aerodromes
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

    /// Errors raised while unpacking an imported archive.
    enum ZipImportError: LocalizedError, Equatable {
        case entryTooLarge, archiveTooLarge, tooManyEntries, sizeMismatch

        var errorDescription: String? {
            switch self {
            case .entryTooLarge: return L10n.FlightLog.importErrorEntryTooLarge
            case .archiveTooLarge: return L10n.FlightLog.importErrorArchiveTooLarge
            case .tooManyEntries: return L10n.FlightLog.importErrorTooManyEntries
            case .sizeMismatch: return L10n.FlightLog.importErrorSizeMismatch
            }
        }
    }

    /// The `.gpx` and `.json` entries of a flight archive, within the SA-24 budgets.
    nonisolated static func extractZipEntries(from data: Data) throws -> [(filename: String, data: Data)] {
        var entries: [(filename: String, data: Data)] = []
        var offset = 0
        // SA-24: decompression budgets. Without these a small deflate stream can expand to several
        // GB in memory and get the app OOM-killed — mid-flight, that kills the flight.
        var totalDecompressedBytes = 0

        while offset < data.count {
            guard entries.count < FlightDataLimits.maxImportEntries else {
                throw ZipImportError.tooManyEntries
            }
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

            // Refuse before allocating: the header's DECLARED size is the cheapest signal we have,
            // so an entry claiming more than the per-entry budget is rejected without decompressing.
            guard Int(uncompressedSize) <= FlightDataLimits.maxImportEntryBytes else {
                throw ZipImportError.entryTooLarge
            }
            guard totalDecompressedBytes + Int(uncompressedSize) <= FlightDataLimits.maxImportTotalBytes else {
                throw ZipImportError.archiveTooLarge
            }

            // Handle compression (method 0 = uncompressed, method 8 = deflate)
            if compressionMethod == 8 {
                // The declared size is attacker-controlled, so it cannot bound memory by being
                // checked: it bounds it by being ENFORCED. The entry is inflated a buffer at a time and
                // abandoned the moment it outgrows its declaration. Checked after a whole-entry
                // decompress, as it was, a header declaring 1 KB (or 0, which skipped the check)
                // expanded 32 MB of zeros to 32 GB first and got the app killed. (S9-29)
                let budget = min(Int(uncompressedSize),
                                 FlightDataLimits.maxImportEntryBytes,
                                 FlightDataLimits.maxImportTotalBytes - totalDecompressedBytes)
                do {
                    fileData = try inflate(fileData, limit: budget)
                } catch is InflateLimitExceeded {
                    throw ZipImportError.sizeMismatch
                }
            }

            // ...and the entry must be exactly the size it declared, stored or inflated. A declared 0
            // no longer waves an entry through.
            guard fileData.count <= FlightDataLimits.maxImportEntryBytes else {
                throw ZipImportError.entryTooLarge
            }
            guard fileData.count == Int(uncompressedSize) else {
                throw ZipImportError.sizeMismatch
            }
            totalDecompressedBytes += fileData.count
            guard totalDecompressedBytes <= FlightDataLimits.maxImportTotalBytes else {
                throw ZipImportError.archiveTooLarge
            }

            entries.append((filename: filename, data: fileData))
            offset = dataEnd
        }

        return entries
    }

    /// Thrown by `inflate` once the output passes its limit. `producedBytes` is how far it got: at
    /// most one buffer past the limit.
    struct InflateLimitExceeded: Error {
        let producedBytes: Int
    }

    /// A malformed or truncated deflate stream.
    struct InflateFailed: Error {}

    /// Inflates one raw DEFLATE stream (a ZIP entry's method 8), stopping as soon as the output
    /// passes `limit`. Foundation's `decompressed(using:)` has no ceiling of its own: it allocates
    /// whatever the stream expands to, which is why SA-24's budget could only be checked after the
    /// damage was done. (S9-29)
    nonisolated static func inflate(_ data: Data, limit: Int, bufferSize: Int = 64 * 1024) throws -> Data {
        guard !data.isEmpty else { throw InflateFailed() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw InflateFailed()
        }
        defer { compression_stream_destroy(stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { throw InflateFailed() }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let inputBefore = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else {
                        throw InflateLimitExceeded(producedBytes: output.count + produced)
                    }
                    output.append(buffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // No output and no input consumed: the stream ended without its final block.
                    if produced == 0 && stream.pointee.src_size == inputBefore { throw InflateFailed() }
                default:
                    throw InflateFailed()
                }
            }
        }
        return output
    }
}

// MARK: - Dashboard metric card (v4 UI/UX Revamp)

/// A compact metric card for the Flight Log dashboard: label + icon, then a big value with an optional
/// unit. (v4 UI/UX Revamp Flight Log revamp)
struct LogMetricCard: View {
    let label: String
    let value: String
    var valueColor: Color = .primaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scaledFont(size: 13, weight: .medium, relativeTo: .caption)
                .foregroundColor(.secondaryText)
            Text(value)
                .scaledFont(size: 26, weight: .bold, design: .rounded, relativeTo: .title2)
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A tiny line sparkline (e.g. a flight's altitude profile) for list rows. Normalised to its own
/// min/max so the shape is visible regardless of absolute values. (v4 UI/UX Revamp)
struct MiniSparkline: View {
    let values: [Double]
    var color: Color = .aviationGold

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let minValue = values.min() ?? 0
                let maxValue = values.max() ?? 1
                let range = max(maxValue - minValue, 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((value - minValue) / range))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Flight Log stats share card (round 7 / customizable round 10)

/// Accent color choices for the stats share card — drives the "FLIGHT LOG" label, the airplane
/// glyph, the HOURS/hero value, and the footer URL. (v4 UI/UX Revamp share-card customization)
enum StatsCardAccent: String, CaseIterable, Identifiable {
    case gold, blue, green, orange, red

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gold: return "Gold"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .red: return "Red"
        }
    }

    var color: Color {
        switch self {
        case .gold: return .aviationGold
        case .blue: return .altimeterBlue
        case .green: return .aviationGreen
        case .orange: return .orange
        case .red: return .aviationRed
        }
    }
}

/// Layout variants for the stats share card. (v4 UI/UX Revamp share-card customization)
enum StatsCardLayout: String, CaseIterable, Identifiable {
    case standard   // four equal stat tiles in a row
    case hero       // a big HOURS hero, then three smaller tiles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Tiles"
        case .hero: return "Hero"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "square.grid.2x2"
        case .hero: return "rectangle.grid.1x2"
        }
    }
}

/// Bundle of customization choices for the stats share card. Theme defaults to the single-flight
/// card's theme so the two share surfaces stay visually consistent. (v4 UI/UX Revamp share-card customization)
struct StatsShareCardOptions {
    var theme: ShareCardColorScheme = .darkBlue
    var accent: StatsCardAccent = .gold
    var layout: StatsCardLayout = .standard
    var showByAircraft: Bool = true
    var showPeriod: Bool = true
}

/// An immutable snapshot of the filtered-log stats, taken when the share sheet opens so the
/// customization preview/render works from a stable dataset. (v4 UI/UX Revamp share-card customization)
struct StatsShareCardData: Identifiable {
    let id = UUID()
    let periodLabel: String
    let hours: Double
    let flights: Int
    let landings: Int
    let distance: Double
    let unit: String
    let byAircraft: [AircraftSlice]

    struct AircraftSlice: Identifiable {
        let id = UUID()
        let name: String
        let hours: Double
        let color: Color
    }
}

/// A shareable stats-summary image of the (filtered) Flight Log: period + the four metric cards +
/// hours-by-aircraft. Theme/accent/layout/content are customizable. Rendered via ImageRenderer.
/// Fixed 1080×1350 (4:5 portrait) so the preview/render size is predictable. (round 7 / round 10)
struct FlightLogStatsShareCard: View {
    // Fixed fonts by design: rendered to a fixed-size share image, not subject to Dynamic Type. (UX-24)
    let periodLabel: String
    let hours: Double
    let flights: Int
    let landings: Int
    let distance: Double
    let unit: String
    let byAircraft: [(name: String, hours: Double, color: Color)]
    var options = StatsShareCardOptions()

    private var theme: ShareCardColorScheme { options.theme }
    private var accent: Color { options.accent.color }

    private static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? value.safeRoundedInt().map(String.init) ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 40) {
                header
                stats
                if options.showByAircraft && !byAircraft.isEmpty {
                    byAircraftSection
                }
            }
            Spacer(minLength: 24)
            footer
        }
        .padding(64)
        .frame(width: 1080, height: 1350, alignment: .topLeading)
        .background(theme.backgroundColor)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("FLIGHT LOG")
                    .font(.aero(size: 26, weight: .semibold)).tracking(6)
                    .foregroundColor(accent)
                if options.showPeriod {
                    Text(periodLabel)
                        .font(.aero(size: 64, weight: .bold))
                        .foregroundColor(theme.primaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            Spacer()
            Image(systemName: "airplane")
                .font(.aero(size: 54))
                .foregroundColor(accent)
        }
    }

    @ViewBuilder
    private var stats: some View {
        switch options.layout {
        case .standard:
            HStack(spacing: 20) {
                statTile("HOURS", String(format: "%.1f", hours), accent)
                statTile("FLIGHTS", "\(flights)", theme.primaryTextColor)
                statTile("LANDINGS", "\(landings)", theme.primaryTextColor)
                statTile(unit.uppercased(), Self.grouped(distance), theme.primaryTextColor)
            }
        case .hero:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HOURS")
                        .font(.aero(size: 24, weight: .semibold)).tracking(2)
                        .foregroundColor(theme.secondaryTextColor)
                    Text(String(format: "%.1f", hours))
                        .font(.aero(size: 170, weight: .bold, design: .rounded))
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
                .background(RoundedRectangle(cornerRadius: 28).fill(theme.cardOverlayColor))

                HStack(spacing: 20) {
                    statTile("FLIGHTS", "\(flights)", theme.primaryTextColor)
                    statTile("LANDINGS", "\(landings)", theme.primaryTextColor)
                    statTile(unit.uppercased(), Self.grouped(distance), theme.primaryTextColor)
                }
            }
        }
    }

    private var byAircraftSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("HOURS BY AIRCRAFT")
                .font(.aero(size: 22, weight: .semibold)).tracking(2)
                .foregroundColor(theme.secondaryTextColor)
            let maxHours = byAircraft.map(\.hours).max() ?? 1
            // Cap at the top 4 aircraft so the fixed-height card never overflows.
            ForEach(Array(byAircraft.prefix(4).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 24) {
                    Text(item.name)
                        .font(.aero(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryTextColor)
                        .frame(width: 240, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.cardOverlayColor)
                            Capsule().fill(item.color)
                                .frame(width: max(24, geo.size.width * CGFloat(item.hours / max(maxHours, 0.01))))
                        }
                    }
                    .frame(height: 22)
                    Text(String(format: "%.1f", item.hours))
                        .font(.aero(size: 30, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.primaryTextColor)
                        .frame(width: 110, alignment: .trailing)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            Image(systemName: "airplane.circle.fill").font(.aero(size: 34)).foregroundColor(accent)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("AéroCheck").font(.aero(size: 26, weight: .semibold)).foregroundColor(theme.primaryTextColor)
                Text("aerocheck.app").font(.aero(size: 20)).foregroundColor(accent)
            }
        }
    }

    private func statTile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.aero(size: 20, weight: .semibold)).tracking(1)
                .foregroundColor(theme.secondaryTextColor)
            Text(value)
                .font(.aero(size: 58, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 24).fill(theme.cardOverlayColor))
    }
}

// MARK: - Flight Row View

struct FlightRowView: View {
    let flight: Flight
    var nauticalMiles: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            // Calendar date block: day over weekday (the month/year lives in the section header). (v4 UI/UX Revamp)
            VStack(spacing: 1) {
                Text(dayNumber)
                    .scaledFont(size: 19, weight: .bold, relativeTo: .title3)
                    .foregroundColor(.aviationGold)
                Text(weekday)
                    .scaledFont(size: 9, weight: .semibold, relativeTo: .caption2).tracking(0.5)
                    .foregroundColor(.dimText)
            }
            .frame(width: 32)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 3) {
                // Custom name (if set) above the route, small/grey like the stats line. (round 7)
                // Never in place of the route: with no aerodrome known it is the title itself. (v6.1)
                if let eyebrow = flight.titleEyebrow {
                    Text(eyebrow)
                        .scaledFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                }
                routeView
                // Secondary: aircraft · landings · distance (time is featured on the right).
                Text(statsLine)
                    .scaledFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Featured total time ON TOP of the altitude sparkline; one line, never wraps. (round 8)
            // More vertical separation between the two — they were cramped while the row had slack. (v4 UI/UX Revamp)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 4) {
                    if flight.isFavorite {
                        Image(systemName: "star.fill")
                            .scaledFont(size: 10, relativeTo: .caption2)
                            .foregroundColor(.aviationGold)
                            .accessibilityLabel("Favorite")
                    }
                    Text(flight.formattedDuration)
                        .scaledFont(size: 15, weight: .bold, design: .monospaced, relativeTo: .subheadline)
                        .foregroundColor(.aviationGreen)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("Duration \(flight.formattedDuration)")
                }
                if sparklineAltitudes.count >= 2 {
                    MiniSparkline(values: sparklineAltitudes, color: .altimeterBlue)
                        .frame(width: 66, height: 18)
                        .accessibilityHidden(true) // decorative altitude glance
                }
            }
        }
        .padding(.vertical, 8)
    }

    // Hoisted out of the two computed properties below, which are read from `body`: a DateFormatter
    // is expensive to construct, and building two per row on every render meant a scrolling logbook
    // allocated a pair for every visible row on every pass. Matches the cached-formatter pattern
    // already used elsewhere in the app. (APP-15)
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private var dayNumber: String {
        guard let date = flight.startTime else { return "—" }
        return Self.dayFormatter.string(from: date)
    }

    /// Weekday abbreviation (e.g. "SAT") under the day number, like a logbook entry. (v4 UI/UX Revamp)
    private var weekday: String {
        guard let date = flight.startTime else { return "" }
        return Self.weekdayFormatter.string(from: date).uppercased()
    }

    /// Route line: "DEP → ARR", "DEP ↻" for a session that came back where it started, a circuits
    /// tag on either when there were touch-and-goes, or a name fallback. (v4 UI/UX Revamp)
    ///
    /// Touch-and-goes alone do not make a flight "circuits": warming up with a few at home before
    /// flying somewhere else is common, and showing only the departure hid where the flight went.
    /// The destination decides the shape; the touch-and-goes add the tag. (v5.2)
    ///
    /// The words are `Flight.title`'s; this only lays them out. A round flight reads "LSZQ", one end
    /// not found reads "LSZQ → ?" with the unknown end dimmed. (v6.1)
    private var routeView: some View {
        routeLine
            // One element, read as the title is meant: "LSZQ to unknown aerodrome, circuits", not
            // "LSZQ, right arrow, question mark". (v6.1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(routeSpokenLabel)
    }

    private var routeSpokenLabel: String {
        switch flight.routeShape {
        case .between(_, _, withCircuits: true), .circuits:
            return "\(flight.spokenTitle), \(L10n.Flights.circuits.lowercased())"
        default:
            return flight.spokenTitle
        }
    }

    @ViewBuilder
    private var routeLine: some View {
        switch flight.routeShape {
        case let .between(dep, arr, withCircuits):
            HStack(spacing: 6) {
                routeIdent(dep)
                routeArrow
                routeIdent(arr)
                if withCircuits { circuitsTag }
            }
        case let .roundTrip(at):
            routeIdent(at)
        case let .oneEnd(dep, arr):
            HStack(spacing: 6) {
                routeIdent(dep)
                routeArrow
                routeIdent(arr)
            }
        case let .circuits(at):
            HStack(spacing: 7) {
                Text(at)
                    .scaledFont(size: 18, weight: .bold, design: .monospaced, relativeTo: .title3)
                    .foregroundColor(.primaryText)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(size: 13, relativeTo: .caption)
                    .foregroundColor(.altimeterBlue)
                circuitsTag
            }
        case .unnamed:
            Text(flight.title)
                .scaledFont(size: 17, weight: .bold, design: .monospaced, relativeTo: .body)
                .foregroundColor(.primaryText)
                .lineLimit(1)
        }
    }

    /// One end of the route; nil is the end that is not known, drawn as a dim "?".
    private func routeIdent(_ ident: String?) -> some View {
        Text(ident ?? Flight.unknownAerodrome)
            .scaledFont(size: 18, weight: .bold, design: .monospaced, relativeTo: .title3)
            .foregroundColor(ident == nil ? .dimText : .primaryText)
    }

    private var routeArrow: some View {
        Image(systemName: "arrow.right").scaledFont(size: 12, weight: .semibold, relativeTo: .caption).foregroundColor(.dimText)
    }

    private var circuitsTag: some View {
        Text(L10n.Flights.circuits.lowercased())
            .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
            .foregroundColor(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
            .lineLimit(1)
    }


    private var statsLine: String { Self.statsLine(for: flight, nauticalMiles: nauticalMiles) }

    /// "HB-KFD · 3 ldg · 42 NM".
    ///
    /// `Int(distance.rounded())` trapped on a cached distance of 1e300 from an imported flight, and
    /// the whole Logbook went down with the row: it could not even be swiped away. The number is
    /// bounded on ingest and load now; the row stays safe for whatever reaches it. (S9-10)
    nonisolated static func statsLine(for flight: Flight, nauticalMiles: Bool) -> String {
        var parts: [String] = [flight.aircraftRegistration ?? flight.airplane]
        if flight.totalLandings > 0 {
            parts.append("\(flight.totalLandings) ldg")
        }
        let distance = nauticalMiles ? flight.distanceKilometers * 0.539957 : flight.distanceKilometers
        if distance >= 0.5, let whole = distance.safeRoundedInt() {
            parts.append("\(whole) \(nauticalMiles ? "NM" : "km")")
        }
        return parts.joined(separator: " · ")
    }

    /// Downsampled altitude (ft) for the row sparkline — a cheap ~60-point glance of the profile. (v4 UI/UX Revamp)
    private var sparklineAltitudes: [Double] {
        // Sample ~60 points by striding the track directly — don't `.map` the whole (possibly
        // thousands-long) GPS track on every row render. (round 9 perf)
        let track = flight.gpsTrack
        guard track.count > 1 else { return track.map { $0.altitude * 3.28084 } }
        let target = min(60, track.count)
        let step = Double(track.count - 1) / Double(target - 1)
        return (0..<target).map { track[Int((Double($0) * step).rounded())].altitude * 3.28084 }
    }
    
}

// MARK: - Logbook day header (6.1)

/// Over a day of two flights or more: "TUE 29 SEP · 3 flights · 1:26 flying · 132 NM" and "Share
/// day", which makes one card of the whole day (the journey card). One line where it fits, the
/// totals under the date where it does not (the iPhone, the two-column list).
struct LogbookDayHeader: View {
    let day: LogbookDay
    let nauticalMiles: Bool
    let onShare: () -> Void

    var body: some View {
        let label = day.label()
        let summary = day.summary(nauticalMiles: nauticalMiles)
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    dateText(label)
                    summaryText(summary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    dateText(label)
                    // Two lines where one is not enough ("Partager la journée" on a phone).
                    Text(verbatim: summary)
                        .scaledFont(size: 14, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button(action: onShare) {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.up")
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    Text(L10n.ShareCard.shareDay)
                        .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                        .lineLimit(1)
                }
                .foregroundColor(.aviationGold)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.aviationGold, lineWidth: 1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func dateText(_ label: String) -> some View {
        Text(verbatim: label)
            .scaledFont(size: 14, weight: .bold, design: .monospaced, relativeTo: .subheadline)
            .tracking(0.8)
            .foregroundColor(.primaryText)
            .lineLimit(1)
            .fixedSize()
    }

    /// In proportional B612: B612 Mono sets "1: 26" (the colon at the left of its space).
    private func summaryText(_ summary: String) -> some View {
        Text(verbatim: summary)
            .scaledFont(size: 14, relativeTo: .caption)
            .foregroundColor(.secondaryText)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Flight Detail View

struct FlightDetailView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) var dismiss
    let flight: Flight

    @State private var flightName: String = ""
    @State private var notes: String = ""
    @State private var showExportSheet = false
    @State private var showDeleteAlert = false
    /// Cost + logbook line for this flight. (v5.0.0)
    @State private var showNumbers = false
    @State private var showExportOptions = false
    @State private var exportType: ExportType = .gpx
    /// A prepared export waiting for the system save dialog.
    @State private var pendingSave: PendingSave?
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
    private func prepareExport(_ type: ExportType, save: Bool = false) {
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
            if let data, save {
                pendingSave = PendingSave(document: ExportDocument(data: data),
                                          contentType: type == .gpx ? (UTType.gpx ?? .xml) : .json,
                                          filename: flight.exportFilename)
            } else if let data {
                preparedExportData = data
                showExportSheet = true
            } else {
                showExportError = true
            }
        }
    }
    
    /// The scrollable detail content, shared by the standalone (pushed) and embedded (2-column) modes.
    private var sectionsStack: some View {
        VStack(spacing: 20) {
            flightHeader
            mapSection
            altitudeGraphSection
            timelineCard
            engineHoursCard
            planVsActualSection
            nameField
            notesSection
            actionsRow
        }
    }

    var body: some View {
        // No own NavigationStack/Close: pushed (single column) it inherits the nav back button; in the
        // 2-column pane it's a placed pane. Either way the redundant Close is gone. (round 9)
        ScrollView {
            sectionsStack
                .padding(20)
        }
        .background(Color.cockpitBackground)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            flightName = flight.name
            notes = flight.notes
        }
        .sheet(isPresented: $showShareCustomization) {
            ShareCardCustomizationView(
                flight: flight,
                appState: appState,
                airports: airportDataService
            )
        }
        .sheet(isPresented: $showNumbers) {
            FlightNumbersView(flightId: flight.id, onClose: { showNumbers = false })
                .environment(appState)
        }
        .confirmationDialog(L10n.FlightDetail.exportFormatTitle, isPresented: $showExportOptions, titleVisibility: .visible) {
            Button(L10n.FlightDetail.exportFormatGPX) {
                prepareExport(.gpx)
            }
            Button(L10n.FlightDetail.exportFormatJSON) {
                prepareExport(.json)
            }
            Button(L10n.Export.saveFormat("GPX")) {
                prepareExport(.gpx, save: true)
            }
            Button(L10n.Export.saveFormat("JSON")) {
                prepareExport(.json, save: true)
            }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            Text(L10n.FlightDetail.exportFormatMessage)
        }
        .fileExporter(isPresented: Binding(get: { pendingSave != nil }, set: { if !$0 { pendingSave = nil } }),
                      document: pendingSave?.document,
                      contentType: pendingSave?.contentType ?? .data,
                      defaultFilename: pendingSave?.filename) { _ in pendingSave = nil }
        .sheet(isPresented: $showExportSheet) {
            // PR-25: data is already serialized off-main in prepareExport — the builder only wraps it.
            if let data = preparedExportData {
                switch exportType {
                case .gpx:
                    ShareSheet(activityItems: [ShareFile(data: data, filename: "\(flight.exportFilename).gpx", dataTypeIdentifier: "com.topografix.gpx")])
                case .json:
                    ShareSheet(activityItems: [ShareFile(data: data, filename: "\(flight.exportFilename).json", dataTypeIdentifier: "public.json")])
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
                                .scaledFont(size: 40, relativeTo: .largeTitle)
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
            // No static title — the Altitude/Speed toggle below the chart is the label (it lied when
            // switched to speed). (round 8)
            if flight.gpsTrack.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .frame(height: 200)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line")
                                .scaledFont(size: 40, relativeTo: .largeTitle)
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

    // MARK: - Redesigned detail sections (round 8)

    /// Date and aircraft. The pilot's name for the flight sits above the title, as in the row. (v6.1)
    private var subtitleLine: String {
        var parts: [String] = []
        if let date = flight.startTime {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            parts.append(formatter.string(from: date))
        }
        parts.append(flight.aircraftRegistration ?? flight.airplane)
        return parts.joined(separator: " · ")
    }

    private var headerDistanceText: String {
        Self.distanceText(for: flight, nauticalMiles: appState.settings.distanceInNauticalMiles)
    }

    private var headerMaxAltText: String { Self.maxAltitudeText(for: flight) }

    /// The header's distance chip. Safe for any value, like the Logbook row's. (S9-10, S9-16)
    nonisolated static func distanceText(for flight: Flight, nauticalMiles nm: Bool) -> String {
        let value = nm ? flight.distanceKilometers * 0.539957 : flight.distanceKilometers
        guard let whole = value.safeRoundedInt() else { return "—" }
        return "\(whole) \(nm ? "NM" : "km")"
    }

    /// The header's maximum altitude chip, in feet. Safe for any value. (S9-10, S9-16)
    nonisolated static func maxAltitudeText(for flight: Flight) -> String {
        let meters = flight.cachedMaxAltitudeMeters ?? flight.gpsTrack.map { $0.altitude }.max()
        guard let feet = meters.flatMap({ ($0 * 3.28084).safeRoundedInt() }) else { return "—" }
        return "\(feet) ft"
    }

    /// Route hero + subtitle + the four stat chips (replaces the old details/route cards). (round 8)
    private var flightHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow = flight.titleEyebrow {
                    Text(eyebrow)
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
                Text(flight.title)
                    .scaledFont(size: 26, weight: .bold, design: .monospaced, relativeTo: .title2)
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(flight.spokenTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(subtitleLine)
                .scaledFont(size: 13, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .lineLimit(2)
            HStack(spacing: 8) {
                statChip("TIME", flight.formattedDuration, .aviationGreen)
                statChip("LDG", "\(flight.totalLandings)", .primaryText)
                statChip(appState.settings.distanceInNauticalMiles ? "NM" : "KM", headerDistanceText, .primaryText)
                statChip("MAX", headerMaxAltText, .primaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).scaledFont(size: 9, weight: .semibold, relativeTo: .caption2).foregroundColor(.dimText)
            Text(value)
                .scaledFont(size: 14, weight: .bold, design: .monospaced, relativeTo: .subheadline)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    /// Chronological event timeline card. (round 8)
    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIMELINE").scaledFont(size: 11, weight: .semibold, relativeTo: .caption2).tracking(0.5).foregroundColor(.secondaryText)
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
        }
    }

    @ViewBuilder
    private var engineHoursCard: some View {
        if flight.engineHourStart != nil || flight.engineHourEnd != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.FlightDetail.engineHours.uppercased()).scaledFont(size: 11, weight: .semibold, relativeTo: .caption2).tracking(0.5).foregroundColor(.secondaryText)
                VStack(spacing: 12) {
                    if let start = flight.engineHourStart {
                        ToggleableHoursRow(label: L10n.FlightDetail.hoursBefore, hours: start, inputFormat: flight.engineHourStartInputFormat, icon: "gauge.with.dots.needle.0percent", color: .aviationGold)
                    }
                    if let end = flight.engineHourEnd {
                        ToggleableHoursRow(label: L10n.FlightDetail.hoursAfter, hours: end, inputFormat: flight.engineHourEndInputFormat, icon: "gauge.with.dots.needle.100percent", color: .aviationGold)
                    }
                    if let formatted = flight.engineHoursFlownFormatted {
                        HStack {
                            Image(systemName: "clock.badge.checkmark").foregroundColor(.aviationGreen).frame(width: 24)
                            Text(L10n.FlightDetail.hoursFlown).font(.bodyText).foregroundColor(.secondaryText)
                            Spacer()
                            Text(formatted).scaledFont(size: 16, weight: .medium, design: .monospaced, relativeTo: .body).foregroundColor(.aviationGreen)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.FlightDetail.flightName).scaledFont(size: 11, weight: .semibold, relativeTo: .caption2).tracking(0.5).foregroundColor(.secondaryText)
            TextField(L10n.FlightDetail.namePlaceholder, text: $flightName)
                .font(.bodyText)
                .foregroundColor(.primaryText)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
                .onChange(of: flightName) { _, newValue in
                    appState.updateFlightName(flight, name: newValue)
                }
        }
    }

    /// Compact actions row: nav plan (if any) · export · share card · delete. (round 8)
    private var actionsRow: some View {
        HStack(spacing: 8) {
            if flight.flightPlan != nil {
                detailActionButton(title: L10n.Nav.navLog, icon: "point.topleft.down.to.point.bottomright.curvepath", tint: .secondaryText) {
                    // The landings at base are placed with the airport data, which loads lazily. (v6.1)
                    Task {
                        await airportDataService.ensureLoaded()
                        showFlightPlan = true
                    }
                }
            }
            // v5.0.0: cost + logbook line. Here as well as on the thread, because a flight flown
            // without a thread still has a cost and still produces a logbook line.
            detailActionButton(title: L10n.Cost.afterTheFlight, icon: "book.closed", tint: .secondaryText) { showNumbers = true }
            detailActionButton(title: L10n.FlightDetail.export, icon: "square.and.arrow.up", tint: .secondaryText) { showExportOptions = true }
            Button { showShareCustomization = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "photo")
                    Text("Share card").lineLimit(1).minimumScaleFactor(0.7)
                }
                .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
            }
            .buttonStyle(.plain)
            Button { showDeleteAlert = true } label: {
                Image(systemName: "trash")
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.aviationRed)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.aviationRed.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showFlightPlan) {
            if let savedFlightPlan = flight.flightPlan {
                // With the passing times the in-flight trigger missed, so the after-flight nav log
                // has its ATO column. Flights logged before this change get them too. The landings are
                // counted from the flight in the same way, at base against the home aerodrome. (v6.1)
                let landings = airportDataService.landingTally(for: flight,
                                                               home: appState.settings.homeAerodromeIdent)
                FlightPlanEditorView(flightPlan: savedFlightPlan.withActualTimesOver(from: flight)
                                        .showingLandings(landings),
                                     isViewingFromFlightLog: true)
                    .environment(appState)
                    .environmentObject(flightPlanManager)
                    .environmentObject(airportDataService)
                    .environmentObject(openAIPDataService)
            }
        }
    }

    private func detailActionButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
            }
            .scaledFont(size: 14, weight: .medium, relativeTo: .subheadline)
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Plan vs Actual (v4 UI/UX Revamp)

    /// Planned ETO vs actual ATO over each waypoint, with the delta, when the flight was flown against a
    /// saved plan that recorded times. Hidden otherwise. (v4 UI/UX Revamp Flight Log revamp)
    @ViewBuilder
    private var planVsActualSection: some View {
        // Passing times the in-flight trigger missed come from the recorded track, and each ATO is
        // compared with the ETO AT that waypoint (not the leg data stored on it, which is the next
        // waypoint's).
        if let plan = flight.flightPlan?.withActualTimesOver(from: flight) {
            let rows = plan.waypoints.indices.filter {
                plan.estimatedTimeOver(at: $0) != nil || plan.waypoints[$0].actualTimeOver != nil
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PLAN vs ACTUAL")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .tracking(0.6)
                        .foregroundColor(.secondaryText)

                    HStack {
                        Text("Waypoint").frame(maxWidth: .infinity, alignment: .leading)
                        Text("ETO").frame(width: 60, alignment: .trailing)
                        Text("ATO").frame(width: 60, alignment: .trailing)
                        Text("Δ").frame(width: 56, alignment: .trailing)
                    }
                    .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundColor(.dimText)

                    ForEach(rows, id: \.self) { index in
                        let waypoint = plan.waypoints[index]
                        let eto = plan.estimatedTimeOver(at: index)
                        // Diverted before reaching it: say so rather than leave a bare "—". (v5.1)
                        let notFlown = plan.diversion.map { index > 0 && index >= $0.leftRouteAt } ?? false
                            && waypoint.actualTimeOver == nil
                        HStack {
                            Text(RouteRadioPlanner.displayName(waypoint, index: index, form: .navLog)
                                 + (notFlown ? " · \(L10n.Trip.notFlown)" : ""))
                                .scaledFont(size: 13, weight: .medium, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(notFlown ? .dimText : .primaryText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(eto.map(planTimeString) ?? "—")
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(.secondaryText)
                                .frame(width: 60, alignment: .trailing)
                            Text(waypoint.actualTimeOver.map(planTimeString) ?? "—")
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(.primaryText)
                                .frame(width: 60, alignment: .trailing)
                            planDeltaView(eto: eto, ato: waypoint.actualTimeOver)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    if let diversion = plan.diversion {
                        HStack {
                            Text("→ \(diversion.ident) · \(diversion.name)")
                                .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(.aviationGold)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("—").frame(width: 60, alignment: .trailing)
                                .foregroundColor(.secondaryText)
                            Text(diversion.landedAt.map(planTimeString) ?? "—")
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(.primaryText)
                                .frame(width: 60, alignment: .trailing)
                            Text("").frame(width: 56)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
            }
        }
    }

    @ViewBuilder
    private func planDeltaView(eto: Date?, ato: Date?) -> some View {
        if let eto, let ato {
            let delta = ato.timeIntervalSince(eto)   // positive = behind/late
            let magnitude = abs(delta).safeInt(or: 0)
            let minutes = magnitude / 60
            let seconds = magnitude % 60
            let sign = delta > 0.5 ? "+" : (delta < -0.5 ? "-" : "")
            // Within a minute = on time (green); late = orange; early = blue.
            let color: Color = abs(delta) < 60 ? .aviationGreen : (delta > 0 ? .orange : .altimeterBlue)
            Text("\(sign)\(minutes):\(String(format: "%02d", seconds))")
                .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption)
                .foregroundColor(color)
        } else {
            Text("—")
                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                .foregroundColor(.dimText)
        }
    }

    private func planTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if appState.settings.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
        }
        return formatter.string(from: date)
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
                    .scaledFont(size: 16, weight: .medium, design: .monospaced, relativeTo: .body)
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
                .scaledFont(size: 16, weight: .medium, design: .monospaced, relativeTo: .body)
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

        // Update ONLY the selected-position marker on scrub. MOVE the existing annotation in place
        // (KVO on `coordinate`) instead of remove+add, which flickered the marker each frame. (round 9)
        if let selected = selectedPoint {
            if let existing = coordinator.selectedAnnotation {
                existing.coordinate = selected.coordinate
            } else {
                let annotation = FlightAnnotation(coordinate: selected.coordinate, title: "Position", isStart: false, isSelected: true)
                mapView.addAnnotation(annotation)
                coordinator.selectedAnnotation = annotation
            }
        } else if let existing = coordinator.selectedAnnotation {
            mapView.removeAnnotation(existing)
            coordinator.selectedAnnotation = nil
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
    // KVO-observable so the selection marker can be MOVED in place on scrub (no remove/add flicker).
    @objc dynamic var coordinate: CLLocationCoordinate2D
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

    /// Which series the chart plots; toggled by the pilot. (v4 UI/UX Revamp)
    enum ChartMode: String, CaseIterable, Identifiable {
        case altitude, speed
        var id: String { rawValue }
        var label: String { self == .altitude ? "Altitude" : "Speed" }
        var unit: String { self == .altitude ? "ft" : "kt" }
    }
    @State private var mode: ChartMode = .altitude

    struct ChartSample { let time: Date; let value: Double }

    // PR-26: each series + Y-range is computed ONCE (downsampled to ~400 points), cached in @State,
    // populated in onAppear — not O(n) computed properties re-run on every scrub frame. Both altitude
    // (ft) and speed (kt) are cached so the toggle is instant. (v4 UI/UX Revamp adds speed)
    @State private var altitudeData: [ChartSample] = []
    @State private var altitudeRange: ClosedRange<Double> = 0...1000
    @State private var speedData: [ChartSample] = []
    @State private var speedRange: ClosedRange<Double> = 0...100

    private var displayData: [ChartSample] { mode == .altitude ? altitudeData : speedData }
    private var displayRange: ClosedRange<Double> { mode == .altitude ? altitudeRange : speedRange }

    /// Populate the cached series + Y-ranges once. Lines are stride-downsampled; the Y-range is taken
    /// from the FULL track so a peak between samples never clips the axis. (PR-26 / 3.3)
    private func populateAltitudeCacheIfNeeded() {
        guard altitudeData.isEmpty, !gpsTrack.isEmpty else { return }
        altitudeData = Self.downsample(gpsTrack, maxPoints: Self.maxChartPoints) { $0.altitude * 3.28084 }
        speedData = Self.downsample(gpsTrack, maxPoints: Self.maxChartPoints) { max(0, $0.speed * 1.94384) }
        let altsFeet = gpsTrack.map { $0.altitude * 3.28084 }
        altitudeRange = Self.paddedRange(min: altsFeet.min() ?? 0, max: altsFeet.max() ?? 1000, pad: 500, snap: 100)
        let speedsKt = gpsTrack.map { max(0, $0.speed * 1.94384) }
        speedRange = Self.paddedRange(min: 0, max: speedsKt.max() ?? 100, pad: 10, snap: 10)
    }

    /// Stride-downsample the track via a value extractor, always keeping the last point so the chart
    /// spans the full flight.
    static func downsample(_ track: [GPSPoint], maxPoints: Int, value: (GPSPoint) -> Double) -> [ChartSample] {
        let samples = track.map { ChartSample(time: $0.timestamp, value: value($0)) }
        guard samples.count > maxPoints, maxPoints > 1 else { return samples }
        let step = Double(samples.count - 1) / Double(maxPoints - 1)
        var result: [ChartSample] = []
        result.reserveCapacity(maxPoints + 1)
        var pos = 0.0
        while Int(pos.rounded()) < samples.count {
            result.append(samples[Int(pos.rounded())])
            pos += step
        }
        if let last = samples.last, result.last?.time != last.time { result.append(last) }
        return result
    }

    /// Range with `pad` padding, snapped to `snap`, never below 0.
    static func paddedRange(min minVal: Double, max maxVal: Double, pad: Double, snap: Double) -> ClosedRange<Double> {
        let lowerBound = Swift.max(0, floor((minVal - pad) / snap) * snap)
        let upperBound = ceil((maxVal + pad) / snap) * snap
        return lowerBound...(upperBound > lowerBound ? upperBound : lowerBound + snap)
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

    /// Value (ft or kt, per `mode`) at the selected time. Binary search (O(log n)) over the
    /// chronological track instead of an O(n) `min(by:)` on every scrub frame. (PR-26 / 3.3)
    private var selectedValue: Double? {
        guard let time = selectedTime, let point = gpsTrack.closestByTimestamp(to: time) else { return nil }
        return mode == .altitude ? point.altitude * 3.28084 : max(0, point.speed * 1.94384)
    }

    var body: some View {
        if gpsTrack.isEmpty {
            Text(L10n.FlightDetail.noAltitudeData)
                .font(.captionText)
                .foregroundColor(.dimText)
        } else {
          VStack(spacing: 10) {
            Chart {
                // Series line
                ForEach(displayData, id: \.time) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value(mode.label, point.value)
                    )
                    .foregroundStyle(Color.altimeterBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                // Area fill under the line
                ForEach(displayData, id: \.time) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Baseline", displayRange.lowerBound),
                        yEnd: .value(mode.label, point.value)
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
                                .scaledFont(size: 12, weight: .medium, relativeTo: .caption)
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
                if let time = selectedTime, let value = selectedValue {
                    RuleMark(x: .value("Selected", time))
                        .foregroundStyle(Color.aviationGold.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Selected", time),
                        y: .value(mode.label, value)
                    )
                    .foregroundStyle(Color.aviationGold)
                    .symbolSize(100)
                    .annotation(position: .top, spacing: 8) {
                        Text("\(value.safeInt.map(String.init) ?? "—") \(mode.unit)")
                            .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
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
                        // AxisMark is not a View — .scaledFont doesn't apply; fixed size stays. (UX-24)
                        .font(.aero(size: 10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dimText.opacity(0.3))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(v.safeInt.map(String.init) ?? "—") \(mode.unit)")
                                .scaledFont(size: 10, relativeTo: .caption2)
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
            .chartYScale(domain: displayRange)
            .chartYAxisLabel(position: .leading, alignment: .center) {
                Text(mode == .altitude ? L10n.FlightDetail.altitudeFtMSL : "Speed (kt)")
                    .scaledFont(size: 10, weight: .medium, relativeTo: .caption2)
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
            .padding(.top, 18)   // room for the top phase-event icon annotations
            .onAppear { populateAltitudeCacheIfNeeded() }

            // Altitude ⇄ speed toggle BELOW the chart, so the top phase icons don't overlap it. (round 8)
            Picker("Series", selection: $mode) {
                Text("Altitude").tag(ChartMode.altitude)
                Text("Speed").tag(ChartMode.speed)
            }
            .pickerStyle(.segmented)
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

/// Present a UIActivityViewController for an image directly via UIKit,
/// bypassing SwiftUI sheet timing issues that can cause grey/empty sheets on first invocation.
@MainActor
func presentImageShareSheet(image: UIImage, filename: String) {
    guard let jpegData = image.jpegData(compressionQuality: shareImageJPEGQuality) else { return }
    presentImageShareSheet(jpegData: jpegData, filename: filename)
}

/// The one JPEG pass a shared image goes through. The flight card used to be encoded twice (0.85,
/// then 0.9 here), which only cost quality. (6.1)
let shareImageJPEGQuality: CGFloat = 0.9

/// The same, for an image already encoded once (off the main thread).
@MainActor
func presentImageShareSheet(jpegData: Data, filename: String) {
    presentImageShareSheet(files: [(jpegData, filename)])
}

/// Several images in one share, in order: the journey card, then each leg's. Most apps show them as
/// a set. (6.1)
@MainActor
func presentImageShareSheet(files: [(data: Data, filename: String)]) {
    // A ShareFile rather than a bare temp URL: the share sheet holds it, and the staged image goes
    // with it once the sheet is closed. It used to stay in tmp/ for good. (S9-06)
    let items = files.map { ShareFile(data: $0.data, filename: $0.filename, dataTypeIdentifier: UTType.jpeg.identifier) }

    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

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

// MARK: - File for Sharing

/// Wraps a `Data` blob so it can be shared via `UIActivityViewController` as a named temp file
/// with an explicit type identifier. Replaces the former byte-identical GPXFile/JSONFile/ZIPFile.
///
/// The PLACEHOLDER is the file's URL. The share sheet decides which actions to offer from the
/// placeholder, and this used to be the filename, a plain string: so it offered text actions only.
/// On a Mac that meant "Copy" and nothing else; on iPad no Print for a PDF and no Save to Files.
///
/// The file is staged on first use, in a directory of its own under `ExportStaging`, and removed
/// with this object: once the share sheet, preview or state holding it lets go. It used to be
/// written into tmp/ with a bare `.atomic` and never removed, a copy of the logbook or a track per
/// share. Staging on first use also means the extra copies SwiftUI makes of a sheet's content
/// write nothing. (S9-06)
class ShareFile: NSObject, UIActivityItemSource {
    let filename: String
    let dataTypeIdentifier: String
    private let root: URL
    /// The bytes until they are staged; released then.
    private var pendingData: Data?
    private var staged: StagedExport?

    init(data: Data, filename: String, dataTypeIdentifier: String, root: URL = ExportStaging.rootDirectory) {
        self.pendingData = data
        self.filename = filename
        self.dataTypeIdentifier = dataTypeIdentifier
        self.root = root
        super.init()
    }

    /// The staged file. A failed write (a full disk) gives an address with nothing behind it, which
    /// the share sheet reports as a failed share, as it always did.
    var url: URL {
        if let staged { return staged.url }
        if let data = pendingData, let file = try? StagedExport(data: data, filename: filename, root: root) {
            staged = file
            pendingData = nil
            return file.url
        }
        return root.appendingPathComponent(ExportStaging.safeFilename(filename))
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return dataTypeIdentifier
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return filename
    }
}

extension Binding where Value == URL? {
    /// Quick Look over a staged export: closing the preview releases the file, which removes it.
    /// (S9-06)
    static func preview(_ file: Binding<StagedExport?>) -> Binding<URL?> {
        Binding(get: { file.wrappedValue?.url },
                set: { if $0 == nil { file.wrappedValue = nil } })
    }
}

// MARK: - Export to Files

/// A generated export handed to `.fileExporter`, so it can be SAVED: a real save panel on the Mac,
/// the Files picker on iPad and iPhone. Sharing alone is not enough there, because the Mac share
/// menu has no Save.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] {
        [.json, .pdf, .xml, .spreadsheet, .commaSeparatedText, .zip, .data] + (UTType.gpx.map { [$0] } ?? [])
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// GPX, as declared by the app's imported type. Nil only if that declaration is missing.
    static var gpx: UTType? { UTType("com.topografix.gpx") ?? UTType(filenameExtension: "gpx") }
}

/// What `.fileExporter` needs for one save.
struct PendingSave {
    let document: ExportDocument
    let contentType: UTType
    let filename: String
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
        case .light: return L10n.ShareCard.themeLight
        case .lightBlue: return L10n.ShareCard.themeAviation
        case .darkBlue: return L10n.ShareCard.themeNavy
        case .dark: return L10n.ShareCard.themeDark
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

    /// The nav map's names for the same layers, so the two pickers agree. (6.1)
    var displayName: String {
        switch self {
        case .standard: return L10n.MapLayer.standard
        case .satellite: return L10n.MapLayer.satellite
        case .icao: return L10n.MapLayer.icao
        case .segelflugkarte: return L10n.ShareCard.gliderChart
        case .swissimage: return L10n.MapLayer.swissimage
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

    /// The swisstopo tiles the layer is made of; nil for Apple's maps. The chart actually drawn can
    /// be another one: `ShareCardMapZoom.choice`. (6.1)
    var tileSource: ShareCardTileSource? {
        switch self {
        case .standard, .satellite: return nil
        case .icao: return .icaoChart
        case .segelflugkarte: return .gliderChart
        case .swissimage: return .swissimage
        }
    }

    /// What the credit line names for this layer.
    var credit: ShareCardMapCredit {
        tileSource?.credit ?? .appleMaps
    }
}

// MARK: - Share Card Customization View

/// Spotify-style customization view for share cards.
/// Shows a live preview with color scheme dots and map layer picker.
struct ShareCardCustomizationView: View {
    let flight: Flight
    var appState: AppState
    /// For the aerodromes' names under the title. Optional: without it the card has the idents only.
    var airports: AirportDataService?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedScheme: ShareCardColorScheme
    @State private var selectedMapLayer: ShareCardMapLayer
    /// The card's look and shape, and whether the ends of the track are cut: remembered on this
    /// device (the theme and the layer sync with the settings; these need no sync). (6.1)
    @AppStorage("shareCard.style") private var selectedStyle: ShareCardStyle = .standard
    @AppStorage("shareCard.format") private var selectedFormat: ShareCardFormat = .story
    @AppStorage("shareCard.hideParking") private var hideParking = false
    @State private var showTerrain: Bool = false
    @State private var terrainData: [(time: Date, elevationFeet: Double)] = []
    @State private var isLoadingTerrain = false
    @State private var previewMapImage: UIImage?
    /// What `previewMapImage` shows, for the credit line: never a layer still loading, and the
    /// national map when a circuit's chart gave way to it. (6.1)
    @State private var previewMapCredit: ShareCardMapCredit?
    /// The chart drawn instead of the one picked (the glider chart, the national map), said under
    /// the layers so the pilot knows why the card does not show the chart they chose. (6.1)
    @State private var mapSubstitute: ShareCardTileSource?
    @State private var mapPlaceholder: ShareCardMapPlaceholder = .loading
    @State private var isLoadingMap = false
    /// Bumped by every map load: a load that ends after a newer one started is dropped, so a quick
    /// run through the layers ends on the last one picked. (6.1)
    @State private var mapLoadGeneration = 0
    @State private var terrainSource: ElevationService.TrackTerrainSource?
    @State private var isGeneratingShare = false
    /// "Bressaucourt → Ecuvillens", once the airport data has answered. (6.1)
    @State private var aerodromeLine: String?
    @State private var isLoadingNames = true
    /// The route as flown, its reporting points qualified from the downloaded data. (6.1)
    @State private var route: [ShareCardRouteStop]

    private let elevationService = ElevationService()

    init(flight: Flight, appState: AppState, airports: AirportDataService? = nil) {
        self.flight = flight
        self.appState = appState
        self.airports = airports
        _selectedScheme = State(initialValue: appState.settings.shareCardColorScheme)
        _selectedMapLayer = State(initialValue: appState.settings.shareCardMapLayer)
        _route = State(initialValue: FlightShareCard.route(for: flight))
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

                    // Style and format (6.1)
                    ShareCardStyleFormatPickers(style: $selectedStyle, format: $selectedFormat)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    // Map layer picker
                    mapLayerPicker
                        .padding(.horizontal, 20)
                        .padding(.bottom, substituteNote == nil ? 14 : 6)

                    if let substituteNote {
                        Text(substituteNote)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // Color scheme dots + terrain toggle
                    HStack {
                        colorSchemePicker

                        Spacer()

                        // Terrain toggle
                        terrainToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    hideParkingToggle
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

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
        .shareCardSheetSizing()
        .task {
            await loadMapPreview()
        }
        .task {
            await loadNames()
        }
        .onChange(of: selectedMapLayer) { _, _ in
            Task { await loadMapPreview() }
        }
        .onChange(of: selectedScheme) { _, _ in
            // The map is drawn over the card's colour, and Apple's maps follow its light or dark.
            Task { await loadMapPreview() }
        }
        .onChange(of: selectedStyle) { _, _ in
            Task { await loadMapPreview() }
        }
        .onChange(of: selectedFormat) { _, _ in
            Task { await loadMapPreview() }
        }
        .onChange(of: hideParking) { _, _ in
            Task { await loadMapPreview() }
        }
        .onChange(of: showTerrain) { _, newValue in
            if newValue && terrainData.isEmpty {
                Task { await loadTerrainData() }
            }
        }
    }

    // MARK: - Card Preview

    private var cardPreview: some View {
        ShareCardPreviewFrame(canvas: selectedFormat.size, isLoadingMap: isLoadingMap,
                              showsRetry: mapPlaceholder == .unavailable && previewMapImage == nil,
                              onRetry: { Task { await loadMapPreview() } }) {
            shareCard(mapImage: previewMapImage)
        }
    }

    /// The card as it is shared, for the preview and for the render: one place, so the two can't
    /// drift apart.
    private func shareCard(mapImage: UIImage?) -> FlightShareCard {
        FlightShareCard(
            flight: flight,
            mapImage: mapImage,
            useUTC: appState.settings.alwaysUseUTC,
            colorScheme: selectedScheme,
            terrainData: shownTerrain,
            nauticalMiles: appState.settings.distanceInNauticalMiles,
            mapPlaceholder: mapPlaceholder,
            credit: ShareCardFigures.credit(map: mapImage == nil ? nil : previewMapCredit,
                                            terrain: shownTerrain.isEmpty ? nil : terrainSource),
            style: selectedStyle,
            format: selectedFormat,
            aerodromeLine: aerodromeLine,
            route: route
        )
    }

    private var shownTerrain: [(time: Date, elevationFeet: Double)] { showTerrain ? terrainData : [] }

    private var substituteNote: String? {
        switch mapSubstitute {
        case .gliderChart?: return L10n.ShareCard.gliderChartNote
        case .nationalMap?: return L10n.ShareCard.nationalMapNote
        default: return nil
        }
    }

    /// Share waits for the map, the terrain and the names: an early tap used to share the card
    /// without them.
    private var canShare: Bool { !isGeneratingShare && !isLoadingMap && !isLoadingTerrain && !isLoadingNames }

    // MARK: - The controls (6.1: shared with the journey's sheet, `ShareCardSheet.swift`)

    /// Off by default: the whole track, as recorded. On, the first and last 300 m go, so the dots no
    /// longer mark where the aircraft is kept. (approved Q7)
    private var hideParkingToggle: some View {
        ShareCardSwitch(isOn: $hideParking, title: L10n.ShareCard.hideParking, hint: L10n.ShareCard.hideParkingHint)
    }

    private var mapLayerPicker: some View {
        ShareCardLayerPicker(selection: selectedMapLayer) { layer in
            selectedMapLayer = layer
            appState.settings.shareCardMapLayer = layer
            appState.saveSettings()
        }
    }

    private var colorSchemePicker: some View {
        ShareCardThemePicker(selection: selectedScheme) { scheme in
            selectedScheme = scheme
            appState.settings.shareCardColorScheme = scheme
            appState.saveSettings()
        }
    }

    private var terrainToggle: some View {
        ShareCardTerrainToggle(isOn: $showTerrain, isLoading: isLoadingTerrain)
    }

    private var shareButton: some View {
        ShareCardShareButton(canShare: canShare, isWorking: isGeneratingShare) {
            Task { await generateAndShare() }
        }
    }

    // MARK: - Helpers

    /// The aerodromes' names under the title, and the reporting points' aerodromes for the route
    /// ("E (LSGC)" for a plan made before 6.0.1 stored it), from the data already on the device.
    /// Nothing is downloaded: without the data the card keeps the idents. (6.1)
    @MainActor
    private func loadNames() async {
        defer { isLoadingNames = false }
        if let airports, airports.isDataAvailable {
            await airports.ensureLoaded()
            aerodromeLine = ShareCardFigures.aerodromeLine(for: flight) { ident in
                airports.findAirport(byIdent: ident)?.name
                    ?? (flight.flightPlan?.diversion?.ident == ident ? flight.flightPlan?.diversion?.name : nil)
            }
        }

        guard let plan = flight.flightPlan,
              plan.waypoints.contains(where: { $0.pointKind == .vrp && ($0.aerodromeICAO ?? "").isEmpty }) else { return }
        let points = OpenAIPReportingPointDataService.shared
        let aerodromes = OpenAIPAirportDataService.shared
        guard points.isDataAvailable else { return }
        await points.ensureLoaded()
        await aerodromes.ensureAerodromeIndexLoaded()
        let qualified = ShareCardRoute.qualifyingReportingPoints(plan) { waypoint in
            waypoint.sourceId.flatMap(points.point(withId:)).flatMap(aerodromes.aerodrome(for:))?.icao
        }
        route = ShareCardRoute.flown(flight, plan: qualified.withActualTimesOver(from: flight))
    }

    /// The map for the selected layer, scheme, style and format, at the exact shape of its frame on
    /// the card. Without a track there is nothing to load; a map that doesn't come is said to be
    /// unavailable, not missing its GPS data. (6.1)
    @MainActor
    private func loadMapPreview() async {
        mapLoadGeneration += 1
        let generation = mapLoadGeneration
        let layer = selectedMapLayer
        let track = hideParking ? ShareCardPrivacy.trimmingParking(flight.gpsTrack) : flight.gpsTrack
        guard track.count >= 2 else {
            previewMapImage = nil
            previewMapCredit = nil
            mapSubstitute = nil
            mapPlaceholder = .noTrack
            isLoadingMap = false
            return
        }
        isLoadingMap = true
        if previewMapImage == nil { mapPlaceholder = .loading }
        let layout = FlightShareCard.layout(for: flight, style: selectedStyle, format: selectedFormat, route: route)
        let request = ShareCardMapRequest(frame: layout.mapFrame,
                                          clearTop: layout.mapClearTop,
                                          clearBottom: layout.mapClearBottom,
                                          style: layout.mapStyle,
                                          track: track.map(\.coordinate),
                                          waypoints: ShareCardRoute.mapWaypoints(flight.flightPlan))
        let map = await ShareCardMapRenderer.render(request, layer: layer, scheme: selectedScheme)
        guard generation == mapLoadGeneration else { return }
        previewMapImage = map?.image
        previewMapCredit = map?.credit
        mapSubstitute = map?.substitute
        // With an image the placeholder is not drawn; `.loading` keeps the next load's spinner clean.
        mapPlaceholder = map == nil ? .unavailable : .loading
        isLoadingMap = false
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
            // The service the profile came from, for the credit line. (6.1)
            if let first = trackPoints.first, let last = trackPoints.last {
                terrainSource = ElevationService.trackTerrainSource(first: first.coordinate, last: last.coordinate)
            }
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

        // Reuse the already-loaded preview map image to avoid re-downloading tiles. The one JPEG
        // pass, off the main thread: it used to be encoded here and again by the share sheet. (6.1)
        let jpegData = await ShareCardExport.jpeg(shareCard(mapImage: previewMapImage), size: selectedFormat.size)

        isGeneratingShare = false
        guard let jpegData else { return }

        // Present share sheet directly via UIKit — avoids SwiftUI's two-sheet
        // transition race condition that causes grey/empty sheets on first export
        // Named like the flight's other exports, so a saved card is found beside them. (v6.1)
        presentImageShareSheet(jpegData: jpegData, filename: "\(flight.exportFilename).jpg")
    }
}

// MARK: - Stats Share Card Customization View

/// Customization sheet for the Flight-Log stats share card: live preview + theme / accent / layout
/// pickers and content toggles, then a full-res render → share. Mirrors `ShareCardCustomizationView`
/// (the single-flight sheet). (v4 UI/UX Revamp share-card customization)
struct StatsShareCardCustomizationView: View {
    let data: StatsShareCardData
    var appState: AppState

    @Environment(\.dismiss) private var dismiss

    @State private var options: StatsShareCardOptions
    @State private var isGenerating = false

    init(data: StatsShareCardData, appState: AppState) {
        self.data = data
        self.appState = appState
        var opts = StatsShareCardOptions()
        // Inherit the single-flight card's theme so the two share surfaces feel consistent.
        opts.theme = appState.settings.shareCardColorScheme
        _options = State(initialValue: opts)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    cardPreview
                        .padding(.top, 12)
                        .padding(.horizontal, 24)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            themePicker
                            accentPicker
                            layoutPicker
                            contentToggles
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    .frame(maxHeight: 280)

                    shareButton
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("Share Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Card

    private var cardView: FlightLogStatsShareCard {
        FlightLogStatsShareCard(
            periodLabel: data.periodLabel,
            hours: data.hours,
            flights: data.flights,
            landings: data.landings,
            distance: data.distance,
            unit: data.unit,
            byAircraft: data.byAircraft.map { (name: $0.name, hours: $0.hours, color: $0.color) },
            options: options
        )
    }

    private var cardPreview: some View {
        GeometryReader { geo in
            let aspect: CGFloat = 1080.0 / 1350.0
            let w = min(geo.size.width, geo.size.height * aspect)
            let h = w / aspect
            cardView
                .scaleEffect(w / 1080.0)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Theme

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("COLOR THEME")
            HStack(spacing: 12) {
                ForEach(ShareCardColorScheme.allCases) { scheme in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            options.theme = scheme
                            appState.settings.shareCardColorScheme = scheme
                            appState.saveSettings()
                        }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(scheme.dotColor).frame(width: 32, height: 32)
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                if options.theme == scheme {
                                    Circle().stroke(Color.aviationGold, lineWidth: 2.5).frame(width: 40, height: 40)
                                }
                            }
                            .frame(width: 44, height: 44)
                            Text(scheme.displayName)
                                .scaledFont(size: 11, weight: .medium, relativeTo: .caption2)
                                .foregroundColor(options.theme == scheme ? .aviationGold : .secondaryText)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Accent

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ACCENT")
            HStack(spacing: 12) {
                ForEach(StatsCardAccent.allCases) { accent in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { options.accent = accent }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(accent.color).frame(width: 32, height: 32)
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                if options.accent == accent {
                                    Circle().stroke(Color.white, lineWidth: 2.5).frame(width: 40, height: 40)
                                }
                            }
                            .frame(width: 44, height: 44)
                            Text(accent.displayName)
                                .scaledFont(size: 11, weight: .medium, relativeTo: .caption2)
                                .foregroundColor(options.accent == accent ? .primaryText : .secondaryText)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Layout

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("LAYOUT")
            HStack(spacing: 10) {
                ForEach(StatsCardLayout.allCases) { layout in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { options.layout = layout }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: layout.icon).scaledFont(size: 13, weight: .medium, relativeTo: .caption)
                            Text(layout.displayName).scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(options.layout == layout ? Color.aviationGold : Color.cardBackground))
                        .foregroundColor(options.layout == layout ? .black : .white)
                    }
                }
            }
        }
    }

    // MARK: - Content toggles

    private var contentToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CONTENT")
            VStack(spacing: 10) {
                toggleRow("Hours by aircraft", isOn: $options.showByAircraft)
                toggleRow("Period title", isOn: $options.showPeriod)
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).scaledFont(size: 15, relativeTo: .subheadline).foregroundColor(.primaryText)
        }
        .tint(.aviationGold)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
            .foregroundColor(.secondaryText)
            .tracking(1.5)
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            Task { await generateAndShare() }
        } label: {
            HStack(spacing: 8) {
                if isGenerating { ProgressView().tint(.black) }
                else { Image(systemName: "square.and.arrow.up") }
                Text("Share").scaledFont(size: 18, weight: .bold, relativeTo: .title3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold))
            .foregroundColor(.black)
        }
        .disabled(isGenerating)
    }

    @MainActor
    private func generateAndShare() async {
        isGenerating = true
        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: 1080, height: 1350)

        // ImageRenderer can return nil on first invocation for complex views — retry briefly.
        var uiImage: UIImage?
        for attempt in 0..<3 {
            uiImage = renderer.uiImage
            if uiImage != nil { break }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }

        isGenerating = false
        guard let image = uiImage else { return }
        presentImageShareSheet(image: image, filename: "AeroCheck_Stats_\(UUID().uuidString.prefix(8)).jpg")
    }
}

// MARK: - Preview

#Preview {
    FlightLogView()
        .environment(AppState())
}
