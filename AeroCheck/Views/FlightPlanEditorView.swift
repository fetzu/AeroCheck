import SwiftUI
import UIKit
import MapKit
import QuickLook
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
        case .gpx: return .gpx ?? .xml  // GPX is XML-based
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
    @EnvironmentObject var threadManager: FlightThreadManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Live "Flight plan details" editor (#5): the route is read-only here (the builder owns it), and
    // changes to the non-route fields auto-commit (debounced) — no Save button, no snapshot split.
    @State private var flightPlan: FlightPlan
    @State private var exportItem: FlightPlanExportItem?
    /// A generated nav log shown in Quick Look, where it can be read, printed or passed on.
    @State private var previewURL: URL?
    /// A generated export waiting for the system save dialog.
    @State private var pendingSave: PendingSave?
    /// Radio plan for the nav log (frequencies, remarks, Radio box), built from the airspace and
    /// airport data when the route changes; also gives the export menu its page count.
    @State private var radioPlan: RouteRadioPlanner.Plan?
    @State private var navLogPages: Int?
    @State private var missingAirspace: [String] = []
    @State private var icaoSectionExpanded = false
    @State private var logbookExpanded = false
    @State private var showingICAOCopied = false
    @State private var commitWork: DispatchWorkItem?
    @State private var notesExpanded = false
    @State private var renaming = false
    @State private var renameText = ""

    /// Whether we're on a compact width device (iPhone)
    /// Note: Using UIDevice instead of horizontalSizeClass because sheets on iPad
    /// report compact size class even though the device has plenty of space
    private var isCompactWidth: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// When true, hides Deactivate/Recalculate buttons (viewing from Flight Log)
    let isViewingFromFlightLog: Bool
    /// "Edit route": opens the route editor. Nil where the sheet was opened FROM the route editor,
    /// which it then returns to. From a flight's page it used to only close the sheet.
    /// (planning proposal A)
    var onEditRoute: (() -> Void)?

    init(flightPlan: FlightPlan, isViewingFromFlightLog: Bool = false, onEditRoute: (() -> Void)? = nil) {
        _flightPlan = State(initialValue: flightPlan)
        self.isViewingFromFlightLog = isViewingFromFlightLog
        self.onEditRoute = onEditRoute
        // What's filled in after the flight stays folded, in its place, until there's something in
        // it: opened from the logbook, or once a time or a counter is set. (planning proposal A1)
        let flown = flightPlan.blockOff != nil || flightPlan.timeOff != nil || flightPlan.counterStart != nil
        _logbookExpanded = State(initialValue: isViewingFromFlightLog || flown)
        _notesExpanded = State(initialValue: !flightPlan.remarks.isEmpty || !flightPlan.debriefing.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // In the order a flight is planned, then what's filled in after it (planning proposal
                // A1): one column of related pairs, computed values as plain text, inputs as fields.
                VStack(spacing: 14) {
                    routeCard
                    departureSection
                    crewSection
                    fuelLedger
                    afterFlightSection
                    notesSection
                    icaoDetailsSection
                    if !isViewingFromFlightLog { actionsSection }
                }
                .padding(16)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
                ToolbarItem(placement: .principal) { titleButton }
                ToolbarItem(placement: .primaryAction) { exportMenu }
                // A decimal pad has no return key, so a pilot who typed a fuel figure had nothing to
                // press and no way to see the field settle. (device pass)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.Button.done) {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .foregroundColor(.aviationGold)
                }
            }
            .alert(L10n.FlightNames.renameFlight, isPresented: $renaming) {
                TextField(L10n.Routes.namePlaceholder, text: $renameText)
                Button(L10n.Button.cancel, role: .cancel) { }
                Button(L10n.Routes.rename) { rename(to: renameText) }
            } message: {
                Text(L10n.FlightNames.renameFlightMessage)
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .quickLookPreview($previewURL)
            .fileExporter(isPresented: Binding(get: { pendingSave != nil }, set: { if !$0 { pendingSave = nil } }),
                          document: pendingSave?.document,
                          contentType: pendingSave?.contentType ?? .data,
                          defaultFilename: pendingSave?.filename) { _ in pendingSave = nil }
            .copiedConfirmation(L10n.Nav.icaoFlightPlanCopied, isPresented: $showingICAOCopied)
        }
        .preferredColorScheme(.dark)
        // AND the local override. A sheet is its own hierarchy, so it inherits neither the root's
        // `.environment(\.colorScheme, .dark)` nor, evidently, enough of `preferredColorScheme` to
        // reach the keyboard — which the system draws in the field's own scheme. (device pass)
        .environment(\.colorScheme, .dark)
        // Room for the form: 578 × 661 pt put four columns in a row and the date picker over the
        // runway. (planning proposal A3)
        .pageSizedSheet()
        // Live: non-route edits auto-commit (debounced) — no Save, no snapshot of the route. (#5)
        .onChange(of: flightPlan) { _, _ in scheduleCommit() }
        .onDisappear { flushCommit() }
        // Frequencies depend on the route and its altitudes only; notes and fuel don't move them.
        // (Waypoint equality is by id, so the key spells out what matters.)
        .task(id: navLogKey) { await refreshNavLogPreview() }
    }

    // MARK: - Title (planning proposal A)

    /// The flight that follows this plan, if one does.
    private var followingThread: FlightThread? { threadManager.thread(forPlanId: flightPlan.id) }

    /// The flight's name (or the route's), then when and with what.
    private var sheetTitle: String {
        if let thread = followingThread { return thread.displayName }
        return flightPlan.name.isEmpty ? routeEndpoints : flightPlan.name
    }

    private var sheetSubtitle: String {
        var parts: [String] = []
        if isFlownByAFlight, let departure = flightPlan.plannedDepartureTime {
            parts.append(departure.formatted(date: .abbreviated, time: .shortened))
        }
        if !flightPlan.aircraftRegistration.isEmpty { parts.append(flightPlan.aircraftRegistration) }
        parts.append(flightPlan.flightType.rawValue)
        return parts.joined(separator: " · ")
    }

    /// The title names the flight, and renames it: whatever its ends. (on-device review #4)
    private var titleButton: some View {
        Button {
            renameText = followingThread?.name ?? flightPlan.name
            renaming = true
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(sheetTitle)
                        .scaledFont(size: 17, weight: .bold, relativeTo: .headline)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                    if !isViewingFromFlightLog {
                        Image(systemName: "pencil")
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                            .foregroundColor(.aviationGold)
                    }
                }
                Text(sheetSubtitle)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isViewingFromFlightLog)
        .accessibilityLabel(sheetTitle)
        .accessibilityHint(L10n.FlightNames.renameFlight)
    }

    private func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let thread = followingThread { threadManager.renameFlight(thread.id, to: trimmed) }
        // The plan carries it too: it titles the nav log.
        flightPlan.name = trimmed
    }

    // MARK: - Route (planning proposal A)

    /// The route, as a picture and its figures. It is edited in the route editor, one tap away.
    private var routeCard: some View {
        HStack(spacing: 14) {
            if flightPlan.waypoints.count >= 2 {
                RouteThumbnail(waypoints: flightPlan.waypoints)
                    .frame(width: isCompactWidth ? 96 : 150, height: isCompactWidth ? 64 : 92)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle(L10n.FlightSheet.route)
                Text(routeEndpoints)
                    .scaledFont(size: 18, weight: .bold, design: .monospaced, relativeTo: .headline)
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(flightPlan.waypoints.count) wpt · \(String(format: "%.0f", flightPlan.totalDistance)) NM · EET \(flightPlan.formattedTotalEET)")
                    .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
            }
            Spacer(minLength: 8)
            if !isViewingFromFlightLog {
                Button {
                    if let onEditRoute { onEditRoute() } else { dismiss() }
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.Nav.editRoute)
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                    }
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.altimeterBlue)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.altimeterBlue.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground))
    }

    // MARK: - Section chrome (planning proposal A)

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
            .tracking(1.2)
            .foregroundColor(.aviationGold)
    }

    private func section<Content: View>(_ title: String, aside: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(title)
                Spacer()
                if let aside {
                    Text(aside).scaledFont(size: 13, relativeTo: .caption).foregroundColor(.secondaryText)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground))
    }

    /// A section folded to one line until opened, in the same place either way.
    private func foldedSection<Content: View>(_ title: String, summary: String, isOpen: Binding<Bool>,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(reduceMotion ? nil : .default) { isOpen.wrappedValue.toggle() } } label: {
                HStack(spacing: 10) {
                    Text(title.uppercased())
                        .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
                        .tracking(1.2)
                        .foregroundColor(isOpen.wrappedValue ? .aviationGold : .secondaryText)
                    if !isOpen.wrappedValue {
                        Text(summary)
                            .scaledFont(size: 13, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen.wrappedValue { content() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground))
    }

    /// Two fields that belong together, side by side; everything else has its own row. (P1)
    private func pair<A: View, B: View>(@ViewBuilder _ a: () -> A, @ViewBuilder _ b: () -> B) -> some View {
        HStack(alignment: .top, spacing: 14) {
            a().frame(maxWidth: .infinity, alignment: .leading)
            b().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Runway designators at the DEPARTURE aerodrome, both ends of each strip, in a stable order.
    /// Empty when the airport layer is not downloaded — which is why the field stays free text.
    private var departureRunwayIdents: [String] {
        guard let ident = flightPlan.waypoints.first?.name, ident.count == 4 else { return [] }
        let ends = airportDataService.getRunways(for: ident.uppercased())
            .filter { !$0.closed }
            .flatMap { [$0.leIdent, $0.heIdent] }
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(ends)).sorted()
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
            // A menu item shows a subtitle when its label is a Label followed by a Text.
            Button { exportFlightPlan(format: .xlsx) } label: {
                Label("Excel", systemImage: "tablecells")
                Text(L10n.Export.allWaypoints)
            }
            Button { exportFlightPlan(format: .pdf) } label: {
                Label("PDF · A4", systemImage: "doc.richtext")
                Text(navLogSubtitle)
            }
            Button { exportFlightPlan(format: .pdfA5) } label: {
                Label("PDF · A5", systemImage: "doc.richtext")
                Text(navLogSubtitle)
            }
            Divider()
            // The nav log on screen: read it, print it, mark it up or pass it on from Quick Look.
            Menu {
                Button("PDF · A4") { exportFlightPlan(format: .pdf, action: .preview) }
                Button("PDF · A5") { exportFlightPlan(format: .pdfA5, action: .preview) }
            } label: {
                Label(L10n.Export.previewPrint, systemImage: "printer")
            }
            // A real save dialog, which the share sheet is not on a Mac.
            Menu {
                Button("GPX") { exportFlightPlan(format: .gpx, action: .save) }
                Button("JSON") { exportFlightPlan(format: .json, action: .save) }
                Button("Excel") { exportFlightPlan(format: .xlsx, action: .save) }
                Button("PDF · A4") { exportFlightPlan(format: .pdf, action: .save) }
                Button("PDF · A5") { exportFlightPlan(format: .pdfA5, action: .save) }
            } label: {
                Label(L10n.Export.saveToFiles, systemImage: "folder")
            }
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

    /// "2 pages · 26 waypoints", plus any country the route crosses without airspace data — shown on
    /// the menu so a multi-page or incomplete nav log is known before it is shared.
    private var navLogSubtitle: String {
        var parts: [String] = []
        if let pages = navLogPages { parts.append(L10n.Export.pages(pages)) }
        parts.append(L10n.Export.waypointCount(flightPlan.waypoints.count))
        if !missingAirspace.isEmpty {
            parts.append(L10n.Export.missingAirspaceShort(missingAirspace.joined(separator: ", ")))
        }
        return parts.joined(separator: " · ")
    }

    private var navLogKey: String {
        flightPlan.waypoints.map { "\($0.latitude),\($0.longitude),\($0.altitude ?? -1),\($0.frequency ?? "")" }
            .joined(separator: ";")
    }

    /// Rebuild the radio plan and page count for the current route.
    private func refreshNavLogPreview() async {
        let plan = flightPlan
        let radio = await RouteRadioPlanner.plan(for: plan, openAIP: openAIPDataService, airports: airportDataService)
        radioPlan = radio
        missingAirspace = plan.waypoints.count >= 2
            ? RouteRadioPlanner.countriesInside(plan.waypoints.map(\.coordinate))
                .filter { !openAIPDataService.downloadedCountries.contains($0) }
            : []
        navLogPages = FlightPlanExportService.navLogPageCount(plan, radio: radio)
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

    /// Whether a flight follows this plan. A plan nobody flies is a ROUTE — timeless, reusable, and
    /// deliberately without a date.
    private var isFlownByAFlight: Bool {
        threadManager.thread(forPlanId: flightPlan.id) != nil
    }

    // MARK: - Departure (planning proposal A1)

    private var departureSection: some View {
        section(L10n.FlightSheet.departure, aside: isFlownByAFlight ? L10n.FlightSheet.localTime : nil) {
            // A ROUTE has no date. It is a path you can fly any day, and giving it one is what let
            // three saved routes all claim to be "today's flight plan". The date belongs to the
            // FLIGHT that uses the route, so it only appears once a flight follows this plan.
            // (device pass) Its own row: in a quarter of the sheet the date and time spilled over
            // the runway. (on-device review #4)
            if isFlownByAFlight {
                // Date AND time: the time is what every ETO on the nav log is counted from.
                DateFormField(label: L10n.FlightSheet.dateAndTime, date: Binding(
                    get: { flightPlan.plannedDepartureTime ?? Date() },
                    set: {
                        flightPlan.plannedDepartureTime = $0
                        // A time the pilot picked replaces a trip leg's estimate. (v5.1)
                        flightPlan.departureIsEstimate = nil
                        flightPlan.calculateRouteData()
                    }
                ), components: [.date, .hourAndMinute])
            }
            pair {
                // The idents come from the departure aerodrome's own runway data; free text stays,
                // for a strip the database doesn't know. (device pass)
                HStack(alignment: .bottom, spacing: 6) {
                    OptionalFormField(label: L10n.Nav.runway, text: $flightPlan.runwayInUse)
                    if !departureRunwayIdents.isEmpty {
                        Menu {
                            ForEach(departureRunwayIdents, id: \.self) { ident in
                                Button(ident) { flightPlan.runwayInUse = ident }
                            }
                            if flightPlan.runwayInUse?.isEmpty == false {
                                Divider()
                                Button(L10n.Button.clear, role: .destructive) { flightPlan.runwayInUse = nil }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .scaledFont(size: 14, weight: .semibold, relativeTo: .body)
                                .foregroundColor(.aviationGold)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L10n.Nav.runway)
                    }
                }
            } _: {
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(text: L10n.Nav.flightType)
                    Menu {
                        Picker("", selection: $flightPlan.flightType) {
                            ForEach(FlightType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                    } label: {
                        HStack {
                            Text(flightPlan.flightType.rawValue)
                                .scaledFont(size: 17, relativeTo: .body)
                                .foregroundColor(.primaryText)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                                .foregroundColor(.aviationGold)
                        }
                        .fieldBox()
                    }
                }
            }
        }
    }

    // MARK: - Crew and aircraft (planning proposal A1)

    private var crewSection: some View {
        section(L10n.FlightSheet.crew) {
            pair {
                FormField(label: L10n.Nav.pilot, text: $flightPlan.pilot)
                    .onAppear {
                        // Settings hold the pilot's name for the logbook. Only fills an EMPTY field,
                        // so a plan flown by someone else is never quietly reassigned. (device pass)
                        if flightPlan.pilot.trimmingCharacters(in: .whitespaces).isEmpty {
                            flightPlan.pilot = appState.settings.pilotName
                        }
                    }
            } _: {
                OptionalFormField(label: L10n.Nav.instructor, text: $flightPlan.instructor)
                    .onAppear {
                        // Same rule as the pilot field: fill an EMPTY one only. (v5.x)
                        guard appState.settings.isStudentPilot,
                              !appState.settings.instructorName.isEmpty,
                              (flightPlan.instructor ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                        else { return }
                        flightPlan.instructor = appState.settings.instructorName
                    }
            }
            // Not an input: the aircraft is the flight's (or the route's), so it reads as text.
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: L10n.Nav.aircraft)
                HStack(spacing: 8) {
                    Text(flightPlan.aircraftRegistration)
                        .scaledFont(size: 17, weight: .bold, design: .monospaced, relativeTo: .body)
                        .foregroundColor(.primaryText)
                    Text(L10n.FlightSheet.aircraftFromFlight(flightPlan.aircraftModelName))
                        .scaledFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(.secondaryText)
                }
            }
        }
    }

    // MARK: - Fuel ledger (planning proposal A2)

    /// The fuel as the paper nav log adds it up: trip + alternate + final reserve + extra = required,
    /// then what's on board, the margin, and the endurance. Inputs are fields, results plain text;
    /// DEFAULT marks what the app filled in, so it gets checked. (FAA EFB human factors §5.1.1,
    /// §5.1.3)
    private var fuelLedger: some View {
        let flow = flightPlan.effectiveFuelFlow
        let flowText = FuelEntry.text(flow)
        let required = flightPlan.fuelRequired
        let onBoard = flightPlan.fuelOnBoard
        let reserveIsDefault = (flightPlan.additionalFuel ?? 0) <= 0
        return section(L10n.FlightSheet.fuel, aside: L10n.FlightSheet.litres) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    ledgerLabel(L10n.FlightSheet.fuelFlow,
                                note: flightPlan.fuelFlow == nil ? L10n.FlightSheet.flowNote : nil,
                                isDefault: flightPlan.fuelFlow == nil)
                    LedgerNumberField(value: Binding(
                        get: { flow },
                        set: {
                            flightPlan.fuelFlow = $0 > 0 ? $0 : nil
                            // The trip fuel is the route's time at this flow: it follows the flow.
                            flightPlan.calculateRouteData()
                        }), format: "%.0f")
                    ledgerUnit("L/h")
                }
                ledgerRule(double: false)
                GridRow {
                    ledgerLabel(L10n.FlightSheet.trip, note: L10n.FlightSheet.tripNote(flightPlan.formattedTotalEET, flowText))
                    ledgerValue(flightPlan.tripFuel)
                    ledgerUnit(L10n.FlightSheet.fromRoute)
                }
                GridRow {
                    ledgerLabel(L10n.FlightSheet.alternate, op: "+")
                    LedgerNumberField(value: Binding(get: { flightPlan.reserveFuel ?? 0 },
                                                     set: { flightPlan.reserveFuel = $0 }), format: "%.1f")
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    ledgerLabel(L10n.FlightSheet.finalReserve, op: "+",
                                note: reserveIsDefault ? L10n.FlightSheet.finalReserveNote(flowText) : nil,
                                isDefault: reserveIsDefault)
                    // The figure Required counts: 45 minutes at the fuel flow until set.
                    LedgerNumberField(value: Binding(get: { flightPlan.finalReserveFuel },
                                                     set: { flightPlan.additionalFuel = $0 }), format: "%.1f")
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    ledgerLabel(L10n.FlightSheet.extra, op: "+")
                    LedgerNumberField(value: Binding(get: { flightPlan.extraFuel ?? 0 },
                                                     set: { flightPlan.extraFuel = $0 }), format: "%.1f")
                    Color.clear.frame(width: 1, height: 1)
                }
                ledgerRule(double: true)
                GridRow {
                    ledgerLabel(L10n.FlightSheet.required, op: "=", bold: true)
                    ledgerValue(required, bold: true)
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    ledgerLabel(L10n.FlightSheet.onBoard, bold: true)
                    LedgerNumberField(value: Binding(get: { onBoard ?? 0 },
                                                     set: { flightPlan.fuelOnBoard = $0 > 0 ? $0 : nil }),
                                      format: "%.1f", emphasised: true)
                    Color.clear.frame(width: 1, height: 1)
                }
                if !isViewingFromFlightLog {
                    GridRow {
                        FullTanksButtons(registration: flightPlan.aircraftRegistration, required: required) { litres in
                            flightPlan.fuelOnBoard = litres
                        }
                        .gridCellColumns(3)
                    }
                }
                GridRow {
                    ledgerLabel(L10n.FlightSheet.margin)
                    marginCells(onBoard: onBoard, required: required, flow: flow)
                }
                GridRow {
                    ledgerLabel(L10n.FlightSheet.endurance, note: L10n.FlightSheet.enduranceNote(flowText))
                    Text(onBoard.map { endurance($0, flow: flow) } ?? "—")
                        .scaledFont(size: 19, design: .monospaced, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .frame(width: 130, alignment: .trailing)
                        .padding(.trailing, 10)
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
    }

    private func ledgerLabel(_ text: String, op: String? = nil, note: String? = nil,
                             isDefault: Bool = false, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(op ?? "")
                .scaledFont(size: 16, design: .monospaced, relativeTo: .body)
                .foregroundColor(.secondaryText)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(text)
                        .scaledFont(size: bold ? 19 : 16, weight: bold ? .bold : .regular, relativeTo: .body)
                        .foregroundColor(.primaryText)
                    if isDefault {
                        Text(L10n.FlightSheet.defaultTag)
                            .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                            .foregroundColor(.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.dimText, lineWidth: 1))
                    }
                }
                if let note {
                    Text(note)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ledgerValue(_ value: Double?, bold: Bool = false) -> some View {
        Text(value.map { String(format: "%.1f", $0) } ?? "—")
            .scaledFont(size: bold ? 21 : 19, weight: bold ? .bold : .regular, design: .monospaced, relativeTo: .body)
            .foregroundColor(.primaryText)
            .frame(width: 130, alignment: .trailing)
            .padding(.trailing, 10)
    }

    private func ledgerUnit(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 13, relativeTo: .caption)
            .foregroundColor(.secondaryText)
            .frame(minWidth: 70, alignment: .leading)
    }

    private func ledgerRule(double: Bool) -> some View {
        GridRow {
            VStack(spacing: 2) {
                Rectangle().fill(Color.white.opacity(double ? 0.35 : 0.12)).frame(height: 1)
                if double { Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1) }
            }
            .gridCellColumns(3)
        }
    }

    @ViewBuilder
    private func marginCells(onBoard: Double?, required: Double?, flow: Double) -> some View {
        switch FuelOnBoardStatus.make(onBoard: onBoard, required: required, flowLitresPerHour: flow) {
        case .notSet:
            Text("—")
                .scaledFont(size: 19, design: .monospaced, relativeTo: .body)
                .foregroundColor(.dimText)
                .frame(width: 130, alignment: .trailing)
                .padding(.trailing, 10)
            Color.clear.frame(width: 1, height: 1)
        case .enough(let margin, let minutes):
            Text("+" + String(format: "%.1f", margin))
                .scaledFont(size: 19, weight: .semibold, design: .monospaced, relativeTo: .body)
                .foregroundColor(.aviationGreen)
                .frame(width: 130, alignment: .trailing)
                .padding(.trailing, 10)
            Text(L10n.FlightSheet.marginMinutes(String(minutes)))
                .scaledFont(size: 13, relativeTo: .caption)
                .foregroundColor(.aviationGreen)
                .frame(minWidth: 70, alignment: .leading)
        case .short(let litres):
            Text("−" + String(format: "%.1f", litres))
                .scaledFont(size: 19, weight: .semibold, design: .monospaced, relativeTo: .body)
                .foregroundColor(.aviationAmber)
                .frame(width: 130, alignment: .trailing)
                .padding(.trailing, 10)
            Text(L10n.FlightSheet.short)
                .scaledFont(size: 13, relativeTo: .caption)
                .foregroundColor(.aviationAmber)
                .frame(minWidth: 70, alignment: .leading)
        }
    }

    private func endurance(_ litres: Double, flow: Double) -> String {
        guard flow > 0 else { return "—" }
        let minutes = Int((litres / flow * 60).rounded(.down))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - After the flight (planning proposal A1)

    /// What's filled in after the flight: folded until then, in the same place either way.
    private var afterFlightSection: some View {
        foldedSection(L10n.FlightSheet.afterFlight, summary: L10n.FlightSheet.afterFlightSummary,
                      isOpen: $logbookExpanded) {
            // Pairs in the nav log's order; Time OFF/ON are the take-off and the landing, not the
            // engine. (v5.2)
            pair {
                OptionalTimeFormField(label: L10n.Nav.blockOff, time: $flightPlan.blockOff)
            } _: {
                OptionalTimeFormField(label: L10n.Nav.blockOn, time: $flightPlan.blockOn)
            }
            pair {
                OptionalTimeFormField(label: L10n.Nav.timeOff, time: $flightPlan.timeOff)
            } _: {
                OptionalTimeFormField(label: L10n.Nav.timeOn, time: $flightPlan.timeOn)
            }
            pair {
                NumberFormField(label: L10n.Nav.counterStart, value: Binding(
                    get: { flightPlan.counterStart ?? 0 },
                    set: { flightPlan.counterStart = $0 }
                ), format: "%.1f")
            } _: {
                NumberFormField(label: L10n.Nav.counterStop, value: Binding(
                    get: { flightPlan.counterStop ?? 0 },
                    set: { flightPlan.counterStop = $0 }
                ), format: "%.1f")
            }
            pair {
                IntFormField(label: L10n.Nav.ldgsAtBase, value: Binding(
                    get: { flightPlan.landingsAtBase ?? 0 },
                    set: { flightPlan.landingsAtBase = $0 }
                ))
            } _: {
                IntFormField(label: L10n.Nav.totalLdgs, value: Binding(
                    get: { calculatedTotalLandings },
                    set: { flightPlan.totalLandings = $0 }
                ))
            }
            // Computed: plain text, not a field.
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: L10n.FlightSheet.airTime)
                Text(formattedAirTime)
                    .scaledFont(size: 17, design: .monospaced, relativeTo: .body)
                    .foregroundColor(.primaryText)
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        foldedSection(L10n.Nav.notes, summary: L10n.FlightSheet.notesSummary, isOpen: $notesExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: L10n.Nav.remarks)
                TextEditor(text: $flightPlan.remarks)
                    .scaledFont(size: 16, relativeTo: .body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: L10n.Nav.debriefing)
                TextEditor(text: $flightPlan.debriefing)
                    .scaledFont(size: 16, relativeTo: .body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    // MARK: - ICAO Details Section

    private var icaoDetailsSection: some View {
        foldedSection(L10n.Nav.icaoDetails, summary: L10n.FlightSheet.atcSummary, isOpen: $icaoSectionExpanded) {
            icaoFieldsContent
        }
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

    /// Take-off (Time OFF) to landing (Time ON), counted like a logbook: the difference of the two
    /// times to the minute. Counter Stop is no longer derived from these: it was Counter Start plus
    /// the engine time Time ON/OFF used to hold, and a meter reading is read, not computed. (v5.2)
    private var formattedAirTime: String {
        guard let takeoff = flightPlan.timeOff, let landing = flightPlan.timeOn, landing >= takeoff else {
            return "--:--"
        }
        let minutes = Flight.loggedMinutes(from: takeoff, to: landing)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
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

    private enum ExportAction { case share, save, preview }

    private func exportFlightPlan(format: FlightPlanExportFormat, action: ExportAction = .share) {
        // Generate the data
        let generatedData: Data?
        switch format {
        case .json:
            generatedData = FlightPlanExportService.exportToJSON(flightPlan)
        case .gpx:
            generatedData = FlightPlanExportService.exportToAvionicsGPX(flightPlan)
        case .xlsx:
            generatedData = FlightPlanExportService.exportToXLSX(flightPlan, radio: radioPlan)
        case .pdf:
            generatedData = FlightPlanExportService.exportToPDF(flightPlan, paperSize: .a4, radio: radioPlan)
        case .pdfA5:
            generatedData = FlightPlanExportService.exportToPDF(flightPlan, paperSize: .a5, radio: radioPlan)
        }

        // Only proceed if data was generated successfully
        guard let data = generatedData else { return }

        switch action {
        case .share:
            // Create export item and show sheet (using item: binding is more reliable than isPresented)
            exportItem = FlightPlanExportItem(
                data: data,
                filename: flightPlan.exportFilename,
                format: format
            )
        case .save:
            pendingSave = PendingSave(document: ExportDocument(data: data), contentType: format.contentType,
                                      filename: flightPlan.exportFilename)
        case .preview:
            previewURL = FlightPlanExportItem(data: data, filename: flightPlan.exportFilename, format: format)?.url
        }
    }
}

// MARK: - Form Fields

/// Shared caption-style label used above every editor form field.
private struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(size: 13, relativeTo: .caption)
            .foregroundColor(.secondaryText)
    }
}

/// Shared input-box chrome (padding + card background + rounded corners) for editor form fields.
/// `dimmed` selects the lighter, read-only variant of the background.
private struct FieldBoxModifier: ViewModifier {
    var dimmed: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(dimmed ? Color.cardBackground.opacity(0.5) : Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9))
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
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: label)

            if isReadOnly {
                Text(text.isEmpty ? "-" : text)
                    .scaledFont(size: 17, design: .monospaced, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldBox(dimmed: true)
            } else {
                TextField("", text: $text)
                    .scaledFont(size: 17, relativeTo: .body)
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
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: label)

            TextField("", text: $localText)
                .scaledFont(size: 17, relativeTo: .body)
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
    var components: DatePickerComponents = [.date]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: label)

            // The system's own compact picker, not a bespoke sheet. The sheet version presented a
            // second sheet on top of the editor's, filled a `.large` detent with a calendar that
            // needed a third of it, and — the reason it had to go — its Done dismissed without the
            // date ever reaching the plan, so the flight could not be moved to another day at all.
            // This writes through the binding as the pilot taps, and iOS sizes its own popover.
            // (device pass)
            // No `fieldBox` here: the compact picker draws its own chip, and a box around it would
            // nest two backgrounds. The vertical padding matches the neighbouring fields so the row
            // still lines up.
            DatePicker("", selection: $date, displayedComponents: components)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.aviationGold)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 5) {
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
                    .scaledFont(size: 17, weight: isSet ? .medium : .regular, design: .monospaced, relativeTo: .body)
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

/// A number you can actually type into.
///
/// `TextField(value:format:)` was three bugs at once. It commits only on end-editing and silently
/// REVERTS anything it cannot parse, so a half-typed "23." became 0 again the moment the field lost
/// focus — which is the "tapping enter just resets it" the device pass found. It ignored `format`
/// entirely, so a computed trip fuel rendered as `23.908338`. And because the bindings behind these
/// fields resolve nil to 0, every empty field displayed a literal "0" that typing appended to: "023".
///
/// Text-backed instead. The value is written on every keystroke, `format` is honoured when the field
/// is not being edited, and focusing a field that reads 0 clears it — a zero there is a placeholder,
/// not a figure the pilot chose. (device pass)
struct NumberFormField: View {
    let label: String
    @Binding var value: Double
    let format: String

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: label)

            TextField("", text: $text)
                .scaledFont(size: 17, design: .monospaced, relativeTo: .body)
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .focused($isEditing)
                .fieldBox()
        }
        .onAppear { text = Self.display(value, format: format) }
        .onChange(of: text) { _, typed in
            // Accept the comma the pilot's keyboard offers in a French locale.
            let normalised = typed.replacingOccurrences(of: ",", with: ".")
            if normalised.isEmpty { value = 0 }
            else if let parsed = Double(normalised) { value = parsed }
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                if value == 0 { text = "" }
            } else {
                text = Self.display(value, format: format)
            }
        }
        // Follow the model when it changes underneath — a fuel figure recomputed from the route —
        // but never while the pilot is mid-number.
        .onChange(of: value) { _, updated in
            if !isEditing { text = Self.display(updated, format: format) }
        }
    }

    private static func display(_ value: Double, format: String) -> String {
        String(format: format, value)
    }
}

/// A ledger cell: the same text-backed number entry as `NumberFormField`, right-aligned under the
/// ledger's other figures, without a label of its own. (planning proposal A2)
struct LedgerNumberField: View {
    @Binding var value: Double
    let format: String
    var emphasised: Bool = false

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("0", text: $text)
            .scaledFont(size: emphasised ? 24 : 19, weight: emphasised ? .bold : .regular,
                        design: .monospaced, relativeTo: .body)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
            .keyboardType(.decimalPad)
            .focused($isEditing)
            .padding(.horizontal, 10)
            .frame(width: 140, height: emphasised ? 52 : 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(emphasised ? Color.aviationGold.opacity(0.8) : Color.clear, lineWidth: 2))
            .onAppear { text = String(format: format, value) }
            .onChange(of: text) { _, typed in
                let normalised = typed.replacingOccurrences(of: ",", with: ".")
                if normalised.isEmpty { value = 0 }
                else if let parsed = Double(normalised) { value = parsed }
            }
            .onChange(of: isEditing) { _, editing in
                if editing { if value == 0 { text = "" } }
                else { text = String(format: format, value) }
            }
            .onChange(of: value) { _, updated in
                if !isEditing { text = String(format: format, updated) }
            }
    }
}

struct IntFormField: View {
    let label: String
    @Binding var value: Int

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: label)

            TextField("", text: $text)
                .scaledFont(size: 17, design: .monospaced, relativeTo: .body)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .focused($isEditing)
                .fieldBox()
        }
        .onAppear { text = String(value) }
        .onChange(of: text) { _, typed in
            let digits = typed.filter(\.isNumber)
            if digits != typed { text = digits; return }
            value = Int(digits) ?? 0
        }
        .onChange(of: isEditing) { _, editing in
            if editing { if value == 0 { text = "" } }
            else { text = String(value) }
        }
        .onChange(of: value) { _, updated in
            if !isEditing { text = String(updated) }
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
