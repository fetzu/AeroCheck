import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// Export format options
enum FlightPlanExportFormat {
    case json
    case gpx  // Avionics-compatible GPX route format (Dynon SkyView, Garmin G3X)
    case xlsx
    case pdf
    /// The same nav log on kneeboard-sized paper. (v5.0.0)
    case pdfA5

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .gpx: return "gpx"
        case .xlsx: return "xlsx"
        case .pdf, .pdfA5: return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .gpx: return .xml  // GPX is XML-based
        case .xlsx: return .spreadsheet
        case .pdf, .pdfA5: return .pdf
        }
    }
}

/// A generated export, written to a temp file so it can go straight to the system share sheet
/// (no intermediate "export ready" screen). (#5 feedback)
struct FlightPlanExportItem: Identifiable {
    let id = UUID()
    let url: URL

    init?(data: Data, filename: String, format: FlightPlanExportFormat) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filename).\(format.fileExtension)")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        self.url = url
    }
}

/// Flight plan editor view - tabular format similar to "AVIS DE VOL" form
struct FlightPlanEditorView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Live "Flight plan details" editor (#5): the route is read-only here (the builder owns it), and
    // changes to the non-route fields auto-commit (debounced) — no Save button, no snapshot split.
    @State private var flightPlan: FlightPlan
    @State private var exportItem: FlightPlanExportItem?
    @State private var icaoSectionExpanded = false
    @State private var logbookExpanded = false
    @State private var showingICAOCopied = false
    @State private var commitWork: DispatchWorkItem?

    /// Whether we're on a compact width device (iPhone)
    /// Note: Using UIDevice instead of horizontalSizeClass because sheets on iPad
    /// report compact size class even though the device has plenty of space
    private var isCompactWidth: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// When true, hides Deactivate/Recalculate buttons (viewing from Flight Log)
    let isViewingFromFlightLog: Bool

    init(flightPlan: FlightPlan, isViewingFromFlightLog: Bool = false) {
        _flightPlan = State(initialValue: flightPlan)
        self.isViewingFromFlightLog = isViewingFromFlightLog
        // Coming from the Flight Log, the Logbook/Times are the point of interest → expand by default;
        // from the planning side they're post-flight noise → stay collapsed. (#5 feedback)
        _logbookExpanded = State(initialValue: isViewingFromFlightLog)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    routeSummaryCard        // route is read-only here — the builder owns it (#5)
                    headerSection
                    fuelSection
                    timingSection           // collapsible "Logbook / times"
                    notesSection
                    icaoDetailsSection
                    if !isViewingFromFlightLog { actionsSection }
                }
                .padding()
                // Add keyboard padding only when needed (handled by system)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            .navigationTitle(flightPlan.name.isEmpty ? L10n.Nav.navLog : flightPlan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) { exportMenu }
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .copiedConfirmation(L10n.Nav.icaoFlightPlanCopied, isPresented: $showingICAOCopied)
        }
        .preferredColorScheme(.dark)
        // Live: non-route edits auto-commit (debounced) — no Save, no snapshot of the route. (#5)
        .onChange(of: flightPlan) { _, _ in scheduleCommit() }
        .onDisappear { flushCommit() }
    }

    // MARK: - Live details helpers (#5)

    /// Read-only route header — editing the route happens in the builder.
    private var routeSummaryCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(routeEndpoints)
                    .scaledFont(size: 16, weight: .bold, design: .monospaced, relativeTo: .body)
                    .foregroundColor(.primaryText).lineLimit(1)
                Text("\(flightPlan.waypoints.count) wpt · \(String(format: "%.0f", flightPlan.totalDistance)) NM · \(flightPlan.formattedTotalEET)")
                    .scaledFont(size: 11, relativeTo: .caption2).foregroundColor(.secondaryText)
            }
            Spacer()
            if !isViewingFromFlightLog {
                Button { dismiss() } label: {
                    Label(L10n.Nav.editRoute, systemImage: "map")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .caption).foregroundColor(.altimeterBlue)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
    }

    private var routeEndpoints: String {
        let names = flightPlan.waypoints.map { $0.name.isEmpty ? L10n.Nav.wpt : $0.name }
        if names.count >= 2, let f = names.first, let l = names.last { return "\(f) → \(l)" }
        return names.first ?? L10n.Nav.flightPlan
    }

    private var exportMenu: some View {
        Menu {
            Button { exportFlightPlan(format: .gpx) } label: { Label("GPX", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            Button { exportFlightPlan(format: .json) } label: { Label("JSON", systemImage: "doc.text") }
            Button { exportFlightPlan(format: .xlsx) } label: { Label("Excel", systemImage: "tablecells") }
            Button { exportFlightPlan(format: .pdf) } label: { Label("PDF · A4", systemImage: "doc.richtext") }
            Button { exportFlightPlan(format: .pdfA5) } label: { Label("PDF · A5", systemImage: "doc.richtext") }
            Divider()
            Button {
                UIPasteboard.general.string = flightPlan.toICAOFlightPlan()
                showingICAOCopied = true
            } label: { Label(L10n.Nav.copyICAOFlightPlan, systemImage: "doc.on.clipboard") }
                .disabled(flightPlan.waypoints.count < 2)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(flightPlan.waypoints.isEmpty)
    }

    /// Debounced auto-commit of non-route edits to the live plan (not for a logged-plan snapshot).
    private func scheduleCommit() {
        guard !isViewingFromFlightLog else { return }
        commitWork?.cancel()
        let work = DispatchWorkItem { flightPlanManager.updateFlightPlan(flightPlan) }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushCommit() {
        commitWork?.cancel()
        guard !isViewingFromFlightLog else { return }
        flightPlanManager.updateFlightPlan(flightPlan)
    }

    // MARK: - Plan (header) Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.Nav.navigationFlightPlan)
                    .scaledFont(size: isCompactWidth ? 12 : 14, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)
                    .tracking(1)
                Spacer()
                HStack(spacing: 8) {
                    Text(L10n.Nav.flightType)
                        .scaledFont(size: isCompactWidth ? 10 : 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                    Picker("", selection: $flightPlan.flightType) {
                        ForEach(FlightType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.aviationGold)
                }
            }

            let cols = isCompactWidth ? 2 : 4
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: cols), spacing: 12) {
                FormField(label: L10n.Nav.pilot, text: $flightPlan.pilot)
                    .onAppear {
                        // Settings now hold the pilot's name for the logbook; a blank field here
                        // meant typing it again on every plan. Only fills an EMPTY field, so a plan
                        // flown by someone else is never quietly reassigned. (device pass)
                        if flightPlan.pilot.trimmingCharacters(in: .whitespaces).isEmpty {
                            flightPlan.pilot = appState.settings.pilotName
                        }
                    }
                FormField(label: L10n.Nav.aircraft, text: .constant(flightPlan.aircraftRegistration), isReadOnly: true)
                DateFormField(label: L10n.Nav.date, date: Binding(
                    get: { flightPlan.plannedDepartureTime ?? Date() },
                    set: { flightPlan.plannedDepartureTime = $0 }
                ))
                OptionalFormField(label: L10n.Nav.runway, text: $flightPlan.runwayInUse, keyboardType: .numberPad)
                OptionalFormField(label: L10n.Nav.instructor, text: $flightPlan.instructor)
                FormField(label: L10n.Nav.totalEET, text: .constant(flightPlan.formattedTotalEET), isReadOnly: true)
                FormField(label: L10n.Nav.distance, text: .constant(String(format: "%.1f NM", flightPlan.totalDistance)), isReadOnly: true)
                FormField(label: L10n.Nav.endurance, text: .constant(flightPlan.formattedEndurance ?? "--:--"), isReadOnly: true)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
    }

    // MARK: - Fuel Section

    private var fuelSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.Nav.fuelCalculation, systemImage: "fuelpump")
                    .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 3), spacing: 12) {
                NumberFormField(
                    label: L10n.Nav.fuelFlow,
                    value: Binding(
                        get: { flightPlan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: flightPlan.aircraftTypeId) },
                        set: { flightPlan.fuelFlow = $0 }
                    ),
                    format: "%.0f"
                )

                NumberFormField(
                    label: L10n.Nav.tripFuel,
                    value: Binding(
                        get: { flightPlan.tripFuel ?? 0 },
                        set: { flightPlan.tripFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: L10n.Nav.reserveFuel,
                    value: Binding(
                        get: { flightPlan.reserveFuel ?? 0 },
                        set: { flightPlan.reserveFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: L10n.Nav.additionalFuel,
                    value: Binding(
                        get: {
                            // Auto-populate with 45 minutes of fuel if not set
                            if let additional = flightPlan.additionalFuel, additional > 0 {
                                return additional
                            }
                            let fuelFlow = flightPlan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: flightPlan.aircraftTypeId)
                            return fuelFlow * 0.75 // 45 minutes = 0.75 hours
                        },
                        set: { flightPlan.additionalFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: L10n.Nav.extraFuel,
                    value: Binding(
                        get: { flightPlan.extraFuel ?? 0 },
                        set: { flightPlan.extraFuel = $0 }
                    ),
                    format: "%.1f"
                )

                FormField(
                    label: L10n.Nav.requiredFuel,
                    text: .constant(flightPlan.fuelRequired.map { String(format: "%.1f", $0) } ?? "--"),
                    isReadOnly: true
                )

                // Fuel ON BOARD had no field anywhere in the app. The model carried it, the thread's
                // fuel task compared against it, and the nav log printed it — but nothing could set
                // it, so that task could never be satisfied and the row sat pending forever.
                // (device pass)
                NumberFormField(
                    label: L10n.Nav.fuelOnBoard,
                    value: Binding(
                        get: { flightPlan.fuelOnBoard ?? 0 },
                        set: { flightPlan.fuelOnBoard = $0 }
                    ),
                    format: "%.1f"
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - Timing Section

    private var timingSection: some View {
        VStack(spacing: 12) {
            // Post-flight logbook data — collapsed by default so it doesn't clutter planning. (#5)
            // No animated expand/collapse under Reduce Motion (UX-18)
            Button { withAnimation(reduceMotion ? nil : .default) { logbookExpanded.toggle() } } label: {
                HStack {
                    Label(L10n.Nav.logbookTimes, systemImage: "clock")
                        .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                        .foregroundColor(.aviationGold)
                    Spacer()
                    Image(systemName: logbookExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, relativeTo: .caption).foregroundColor(.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if logbookExpanded {
            // First row: Counter Start, Block OFF, Time ON, Time OFF, Block ON, Counter Stop
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 6), spacing: 12) {
                NumberFormField(
                    label: L10n.Nav.counterStart,
                    value: Binding(
                        get: { flightPlan.counterStart ?? 0 },
                        set: { flightPlan.counterStart = $0 }
                    ),
                    format: "%.1f"
                )

                OptionalTimeFormField(label: L10n.Nav.blockOff, time: $flightPlan.blockOff)
                OptionalTimeFormField(label: L10n.Nav.timeOn, time: $flightPlan.timeOn)
                OptionalTimeFormField(label: L10n.Nav.timeOff, time: $flightPlan.timeOff)
                OptionalTimeFormField(label: L10n.Nav.blockOn, time: $flightPlan.blockOn)

                NumberFormField(
                    label: L10n.Nav.counterStop,
                    value: Binding(
                        get: { calculatedCounterStop },
                        set: { flightPlan.counterStop = $0 }
                    ),
                    format: "%.1f"
                )
            }

            // Second row: Landings and Engine Time
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 6), spacing: 12) {
                IntFormField(
                    label: L10n.Nav.ldgsAtBase,
                    value: Binding(
                        get: { flightPlan.landingsAtBase ?? 0 },
                        set: { flightPlan.landingsAtBase = $0 }
                    )
                )

                IntFormField(
                    label: L10n.Nav.totalLdgs,
                    value: Binding(
                        get: { calculatedTotalLandings },
                        set: { flightPlan.totalLandings = $0 }
                    )
                )

                // Engine Time display (HH:MM format)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Nav.engineTime)
                        .scaledFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.secondaryText)
                    Text(formattedEngineTime)
                        .scaledFont(size: 14, weight: .medium, design: .monospaced, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.cardBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Empty cells to maintain grid alignment
                Spacer()
                Spacer()
                Spacer()
            }
            } // if logbookExpanded
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.Nav.notes, systemImage: "note.text")
                    .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Nav.remarks)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)

                TextEditor(text: $flightPlan.remarks)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Nav.debriefing)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)

                TextEditor(text: $flightPlan.debriefing)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - ICAO Details Section

    private var icaoDetailsSection: some View {
        VStack(spacing: 12) {
            // No animated expand/collapse under Reduce Motion (UX-18)
            Button(action: { withAnimation(reduceMotion ? nil : .default) { icaoSectionExpanded.toggle() } }) {
                HStack {
                    Label(L10n.Nav.icaoDetails, systemImage: "doc.plaintext")
                        .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                        .foregroundColor(.aviationGold)

                    Spacer()

                    Image(systemName: icaoSectionExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if icaoSectionExpanded {
                icaoFieldsContent
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    private var icaoFieldsContent: some View {
        VStack(spacing: 12) {
            icaoFieldRow(label: L10n.Nav.icaoAircraftType, placeholder: flightPlan.resolvedICAOType, binding: Binding(
                get: { flightPlan.icaoAircraftType ?? "" },
                set: { flightPlan.icaoAircraftType = $0.isEmpty ? nil : $0 }
            ))

            // Wake turbulence category picker
            HStack {
                Text(L10n.Nav.wakeTurbulence)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .frame(width: 140, alignment: .leading)

                Picker("", selection: Binding(
                    get: { flightPlan.wakeTurbulenceCategory ?? "L" },
                    set: { flightPlan.wakeTurbulenceCategory = $0 }
                )) {
                    Text("L").tag("L")
                    Text("M").tag("M")
                    Text("H").tag("H")
                }
                .pickerStyle(.segmented)
            }

            icaoFieldRow(label: L10n.Nav.equipmentCodes, placeholder: "S", binding: Binding(
                get: { flightPlan.equipmentCodes ?? "" },
                set: { flightPlan.equipmentCodes = $0.isEmpty ? nil : $0 }
            ))

            icaoFieldRow(label: L10n.Nav.surveillanceCodes, placeholder: "N", binding: Binding(
                get: { flightPlan.surveillanceCodes ?? "" },
                set: { flightPlan.surveillanceCodes = $0.isEmpty ? nil : $0 }
            ))

            icaoFieldRow(label: L10n.Nav.alternateAerodrome, placeholder: "LFGB", binding: Binding(
                get: { flightPlan.alternateAerodrome ?? "" },
                set: { flightPlan.alternateAerodrome = $0.isEmpty ? nil : $0 }
            ))

            // Persons on board
            HStack {
                Text(L10n.Nav.personsOnBoard)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .frame(width: 140, alignment: .leading)

                TextField("1", text: Binding(
                    get: { flightPlan.personsOnBoard.map { String($0) } ?? "" },
                    set: { flightPlan.personsOnBoard = Int($0) }
                ))
                .keyboardType(.numberPad)
                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                .textFieldStyle(.roundedBorder)
            }

            icaoFieldRow(label: L10n.Nav.aircraftColour, placeholder: "WHITE RED", binding: Binding(
                get: { flightPlan.aircraftColour ?? "" },
                set: { flightPlan.aircraftColour = $0.isEmpty ? nil : $0 }
            ))
        }
    }

    private func icaoFieldRow(label: String, placeholder: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .frame(width: 140, alignment: .leading)

            TextField(placeholder, text: binding)
                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.allCharacters)
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 12) {
            if flightPlan.id == flightPlanManager.activeFlightPlan?.id {
                Button { flightPlanManager.deactivateFlightPlan() } label: {
                    Label(L10n.Nav.deactivateFlightPlan, systemImage: "airplane.arrival").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            } else {
                Button {
                    flightPlanManager.updateFlightPlan(flightPlan)
                    flightPlanManager.activateFlightPlan(flightPlan)
                    dismiss()
                } label: {
                    Label(L10n.Nav.activateFlightPlan, systemImage: "airplane.departure").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.aviationGreen)
            }
        }
        .padding()
    }

    // MARK: - Export Section

    // MARK: - Computed Properties for Auto-Population

    /// Calculate Counter Stop based on Counter Start + Engine Time
    /// Engine Time = Time OFF (engine stop) - Time ON (engine start)
    private var calculatedCounterStop: Double {
        // If explicitly set, use that value
        if let counterStop = flightPlan.counterStop, counterStop > 0 {
            return counterStop
        }

        // Otherwise, try to calculate from counter start + engine time
        guard let counterStart = flightPlan.counterStart,
              let timeOn = flightPlan.timeOn,
              let timeOff = flightPlan.timeOff else {
            return flightPlan.counterStop ?? 0
        }

        // Engine time in hours (Hobbs meter is in decimal hours)
        let engineTimeSeconds = timeOff.timeIntervalSince(timeOn)
        let engineTimeHours = engineTimeSeconds / 3600.0

        return counterStart + engineTimeHours
    }

    /// Format engine time as HH:MM (from Time ON = engine start to Time OFF = engine stop)
    /// Same format as Flight Log detail view duration
    private var formattedEngineTime: String {
        guard let timeOn = flightPlan.timeOn,
              let timeOff = flightPlan.timeOff else {
            return "--:--"
        }

        let engineTimeSeconds = timeOff.timeIntervalSince(timeOn)
        if engineTimeSeconds < 0 { return "--:--" }

        let hours = Int(engineTimeSeconds) / 3600
        let minutes = (Int(engineTimeSeconds) % 3600) / 60

        return String(format: "%02d:%02d", hours, minutes)
    }

    /// Calculate Total Landings from current flight if available
    private var calculatedTotalLandings: Int {
        // If explicitly set, use that value
        if let totalLandings = flightPlan.totalLandings, totalLandings > 0 {
            return totalLandings
        }

        // Try to get from current flight
        if let currentFlight = appState.currentFlight {
            return currentFlight.totalLandings
        }

        return flightPlan.totalLandings ?? 0
    }

    private func exportFlightPlan(format: FlightPlanExportFormat) {
        // Generate the data
        let generatedData: Data?
        switch format {
        case .json:
            generatedData = FlightPlanExportService.exportToJSON(flightPlan)
        case .gpx:
            generatedData = FlightPlanExportService.exportToAvionicsGPX(flightPlan)
        case .xlsx:
            generatedData = FlightPlanExportService.exportToXLSX(flightPlan)
        case .pdf:
            generatedData = FlightPlanExportService.exportToPDF(flightPlan, paperSize: .a4)
        case .pdfA5:
            generatedData = FlightPlanExportService.exportToPDF(flightPlan, paperSize: .a5)
        }

        // Only proceed if data was generated successfully
        guard let data = generatedData else { return }

        // Create export item and show sheet (using item: binding is more reliable than isPresented)
        exportItem = FlightPlanExportItem(
            data: data,
            filename: flightPlan.exportFilename,
            format: format
        )
    }
}

// MARK: - Form Fields

/// Shared caption-style label used above every editor form field.
private struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(size: 11, relativeTo: .caption2)
            .foregroundColor(.secondaryText)
    }
}

/// Shared input-box chrome (padding + card background + rounded corners) for editor form fields.
/// `dimmed` selects the lighter, read-only variant of the background.
private struct FieldBoxModifier: ViewModifier {
    var dimmed: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(dimmed ? Color.cardBackground.opacity(0.5) : Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private extension View {
    func fieldBox(dimmed: Bool = false) -> some View {
        modifier(FieldBoxModifier(dimmed: dimmed))
    }
}

struct FormField: View {
    let label: String
    @Binding var text: String
    var isReadOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)

            if isReadOnly {
                Text(text.isEmpty ? "-" : text)
                    .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldBox(dimmed: true)
            } else {
                TextField("", text: $text)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .textFieldStyle(.plain)
                    .fieldBox()
            }
        }
    }
}

/// Form field for optional string values
struct OptionalFormField: View {
    let label: String
    @Binding var text: String?
    var keyboardType: UIKeyboardType = .default

    @State private var localText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)

            TextField("", text: $localText)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .textFieldStyle(.plain)
                .keyboardType(keyboardType)
                .fieldBox()
                .onAppear {
                    localText = text ?? ""
                }
                .onChange(of: localText) { _, newValue in
                    text = newValue.isEmpty ? nil : newValue
                }
                .onChange(of: text) { _, newValue in
                    let newText = newValue ?? ""
                    if newText != localText {
                        localText = newText
                    }
                }
        }
    }
}

struct DateFormField: View {
    let label: String
    @Binding var date: Date

    @State private var showingDatePicker = false

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)

            // Display date as styled text, tap to edit
            Button(action: { showingDatePicker = true }) {
                Text(dateFormatter.string(from: date))
                    .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldBox()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(selectedDate: $date, isPresented: $showingDatePicker)
        }
    }
}

/// Shared header for the compact date/time picker sheets: title + spacer + Done button.
private struct SheetHeader: View {
    let title: String
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            Text(title)
                .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
                .foregroundColor(.primaryText)

            Spacer()

            Button(L10n.Button.done) {
                isPresented = false
            }
            .scaledFont(size: 16, weight: .medium, relativeTo: .body)
            .foregroundColor(.aviationGold)
        }
        .padding(.horizontal)
        .padding(.top, 16)
    }
}

/// Compact sheet for picking date (popover-style)
struct DatePickerSheet: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            SheetHeader(title: L10n.Nav.selectDate, isPresented: $isPresented)

            // Date picker
            DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.graphical)
                .tint(.aviationGold)

            Spacer()
        }
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

struct OptionalTimeFormField: View {
    let label: String
    @Binding var time: Date?

    @State private var isSet: Bool = false
    @State private var selectedTime: Date = Date()
    @State private var showingPicker: Bool = false

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)

            Button(action: {
                if !isSet {
                    selectedTime = Date()
                    time = selectedTime
                    isSet = true
                }
                showingPicker = true
            }) {
                Text(isSet ? timeFormatter.string(from: selectedTime) : L10n.Nav.set)
                    .scaledFont(size: 14, weight: isSet ? .medium : .regular, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(isSet ? .primaryText : .aviationGold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldBox()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingPicker) {
            TimePickerSheet(selectedTime: $selectedTime, isPresented: $showingPicker)
                .onChange(of: selectedTime) { _, newValue in
                    time = newValue
                }
        }
        .onAppear {
            if let existingTime = time {
                selectedTime = existingTime
                isSet = true
            }
        }
    }
}

/// Compact sheet for picking time (popover-style)
struct TimePickerSheet: View {
    @Binding var selectedTime: Date
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            SheetHeader(title: L10n.Nav.selectTime, isPresented: $isPresented)

            // Compact time picker
            DatePicker("", selection: $selectedTime, displayedComponents: [.hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.wheel)
                .frame(height: 150)
                .clipped()

            Spacer()
        }
        .frame(maxHeight: 280)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

struct NumberFormField: View {
    let label: String
    @Binding var value: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)

            TextField("", value: $value, format: .number)
                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .fieldBox()
        }
    }
}

struct IntFormField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)

            TextField("", value: $value, format: .number)
                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .fieldBox()
        }
    }
}

// MARK: - Waypoint Picker Map View Representable

/// Map layers for the waypoint-picker / route-builder maps. (shared by the builder + waypoint sheet)
enum WaypointPickerMapLayer: String, CaseIterable, Identifiable {
    case apple = "Apple Maps"
    case icao = "ICAO / Segelflug"
    case swissimage = "SwissImage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .apple: return "map"
        case .icao: return "airplane"
        case .swissimage: return "photo"
        }
    }
}

struct WaypointPickerMapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let mapLayer: WaypointPickerMapLayer
    var airports: [Airport] = []
    var onAirportTapped: ((Airport) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        configureMapLayer(mapView)
        mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        return mapView
    }

    private func cameraZoomRange(for layer: WaypointPickerMapLayer) -> MKMapView.CameraZoomRange? {
        switch layer {
        case .apple:
            return MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 100,
                maxCenterCoordinateDistance: 10_000_000
            )
        case .icao:
            // ICAO + Segelflugkarte: zoom 7-12, matching NavigationView values
            return MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 65_000,
                maxCenterCoordinateDistance: 600_000
            )
        case .swissimage:
            // SWISSIMAGE: zoom 7-18
            return MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 1_500,
                maxCenterCoordinateDistance: 600_000
            )
        }
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Only reconfigure tiles when layer actually changes
        if context.coordinator.currentLayer != mapLayer {
            context.coordinator.currentLayer = mapLayer
            configureMapLayer(mapView)
            mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        }
        // Update airport annotations (already uses diff logic)
        updateAirportAnnotations(mapView)
    }

    private func updateAirportAnnotations(_ mapView: MKMapView) {
        let existingAirportAnnotations = mapView.annotations.compactMap { $0 as? AirportAnnotation }
        let existingIds = Set(existingAirportAnnotations.map { $0.airport.id })
        let newIds = Set(airports.map { $0.id })

        let toRemove = existingAirportAnnotations.filter { !newIds.contains($0.airport.id) }
        mapView.removeAnnotations(toRemove)

        let toAdd = airports.filter { !existingIds.contains($0.id) }
        for airport in toAdd {
            let annotation = AirportAnnotation(airport: airport)
            mapView.addAnnotation(annotation)
        }
    }

    private func configureMapLayer(_ mapView: MKMapView) {
        // Remove existing tile overlays
        let existingTileOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        mapView.removeOverlays(existingTileOverlays)

        switch mapLayer {
        case .apple:
            mapView.mapType = .standard

        case .icao:
            mapView.mapType = .standard
            let overlay = ICAOSegelflugkarteTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)

        case .swissimage:
            mapView.mapType = .standard
            let overlay = SwisstopoTileOverlay(
                layerIdentifier: "ch.swisstopo.swissimage",
                tileExtension: "jpeg"
            )
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: WaypointPickerMapViewRepresentable
        var currentLayer: WaypointPickerMapLayer
        var isUserInteracting = false

        init(_ parent: WaypointPickerMapViewRepresentable) {
            self.parent = parent
            self.currentLayer = parent.mapLayer
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if let gestureRecognizers = mapView.subviews.first?.gestureRecognizers {
                for recognizer in gestureRecognizers {
                    if recognizer.state == .began || recognizer.state == .changed {
                        isUserInteracting = true
                        return
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isUserInteracting = false
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is AirportAnnotation else { return nil }

            let identifier = "WaypointPickerAirport"
            let annotationView: MKAnnotationView

            if let reusedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reusedView.annotation = annotation
                annotationView = reusedView
            } else {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }

            annotationView.canShowCallout = true

            let size: CGFloat = 14
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            let color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9)
            if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                annotationView.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            }

            // Add a tap button as right callout accessory to add to route
            let addButton = UIButton(type: .contactAdd)
            annotationView.rightCalloutAccessoryView = addButton

            return annotationView
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let airportAnnotation = view.annotation as? AirportAnnotation else { return }
            parent.onAirportTapped?(airportAnnotation.airport)
        }
    }
}

// MARK: - Preview

#Preview {
    FlightPlanEditorView(flightPlan: FlightPlan(name: "Test Flight"))
        .environment(AppState())
        .environmentObject(FlightPlanManager())
        .environmentObject(AirportDataService())
        .environmentObject(OpenAIPDataService())
}
