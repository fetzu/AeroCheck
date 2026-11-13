import SwiftUI

// MARK: - The mass and balance sheet (6.11.0)
//
// A ground screen, used at home the evening before and standing at the aircraft: 17 pt text at least,
// 22 pt figures, controls 52 pt high. It is never offered in flight. The pilot types kilograms and
// litres; every figure is also shown in the handbook's own units, so the result can be held against
// the paper form.
//
// The iPad shows the cabin from above and, under it, the same load as the handbook's table. The
// iPhone shows the load as rows, with a one-line verdict and a small chart that stay on top.
// (the author's m5, m6, m10)

/// What opens for a registration: the sheet when there is data to compute with, the 5.0.0 calculator
/// with the pilot's own figures when there is none.
/// The flight a sheet is opened for: what it starts with, and where a change goes. Without one the
/// sheet is a check of the aircraft alone (Today, Settings), kept per registration.
struct MassBalanceFlightContext {
    /// `MassBalanceFlight.startingLoad`: nil starts the sheet from nothing.
    var load: MassBalanceLoad?
    var onChange: (MassBalanceLoad) -> Void
}

struct MassBalanceEntryView: View {
    let registration: String
    var flight: MassBalanceFlightContext?
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var aircraftDataService: AircraftDataService
    @State private var showSteps = false
    @State private var showOwn = false
    @State private var showChoices = false

    private var shipped: AircraftMassBalance? {
        _ = aircraftDataService.massBalanceChangeCount
        return aircraftDataService.massBalance(forRegistration: registration)
    }

    /// Whether the pilot set the 5.0.0 calculator up for this aircraft: it stays theirs to use.
    private var hasOldFigures: Bool {
        appState.settings.weightBalanceProfiles[registration]?.isConfigured ?? false
    }

    var body: some View {
        let setup = appState.settings.massBalance[registration]
        Group {
            if let basis = setup.basis(shipped: shipped, now: Date()) {
                // A page on the iPad, so the seat plan and the handbook's table have their width;
                // iPadOS 17 keeps the form sheet and shows the rows of the iPhone in it.
                MassBalanceSheetView(registration: registration, basis: basis, shipped: shipped, flight: flight,
                                     onClose: onClose)
                    .pageSizedSheet()
            } else if hasOldFigures {
                // No data to compute with, and the pilot's 5.0.0 calculator is set up: it opens as it
                // always did, with the way to the new sheet above it.
                WeightBalanceView(registration: registration, onClose: onClose,
                                  notice: shipped == nil ? L10n.MassBalance.ownOldNotice : L10n.MassBalance.nodataDeclined(registration),
                                  noticeAction: L10n.MassBalance.ownChoices,
                                  onNotice: { showChoices = true })
            } else {
                // No data from the server, or data the pilot said isn't this aircraft's: their own figures.
                noData { if let onClose { onClose() } }
            }
        }
        .sheet(isPresented: $showChoices) {
            noData { showChoices = false }
        }
        .sheet(isPresented: $showSteps) {
            if let shipped {
                MassBalanceSetupSteps(registration: registration, shipped: shipped) { showSteps = false }
                    .environment(appState)
            }
        }
        .sheet(isPresented: $showOwn) {
            MassBalanceOwnFiguresView(registration: registration) { showOwn = false }
                .environment(appState)
        }
        .task { await aircraftDataService.refreshMassBalance(forRegistration: registration) }
    }

    /// The ways on from "no data": the pilot's own figures, the app's data again when it was switched off.
    /// One sheet at a time: the choices close before the next opens.
    private func noData(onClose close: @escaping () -> Void) -> some View {
        MassBalanceNoDataView(
            registration: registration, isDeclined: shipped != nil,
            onEnter: { open { showOwn = true } },
            onLookAgain: { open { showSteps = true } },
            onClose: close)
    }

    private func open(_ next: @escaping () -> Void) {
        guard showChoices else { return next() }
        showChoices = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: next)
    }
}

struct MassBalanceSheetView: View {
    let registration: String
    let basis: MassBalanceBasis
    let shipped: AircraftMassBalance?
    var flight: MassBalanceFlightContext?
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var load = MassBalanceLoad()
    @State private var loaded = false
    /// What the sheet opened with. Opening a sheet writes nothing: only a change does.
    @State private var opened: MassBalanceLoad?
    @State private var showSteps = false
    @State private var showOwn = false

    private var data: AircraftMassBalance { basis.data }
    private var result: MassBalanceResult {
        MassBalanceCalculator.compute(data: data, empty: basis.empty, load: load, isConfirmed: basis.isConfirmed)
    }
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        let result = self.result
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        if isWide {
                            verdict(result)
                            HStack(alignment: .top, spacing: 14) {
                                MassBalanceChart(data: data, result: result)
                                    .frame(height: 380)
                                MassBalancePointCards(data: data, result: result, stacked: true)
                                    .frame(width: 230)
                            }
                            MassBalanceSectionTitle(text: L10n.MassBalance.loadTitle, note: L10n.MassBalance.loadUnits)
                            MassBalanceSeatPlan(data: data, empty: basis.empty, result: result, load: $load)
                            MassBalanceSectionTitle(text: L10n.MassBalance.tableTitle, note: nil)
                            MassBalanceLoadTable(data: data, empty: basis.empty, result: result, load: load)
                        } else {
                            MassBalanceVerdictLines(lines: lines(result), verdict: result.verdict,
                                                    onTodays: sayTodays, onCheckData: canCheckData ? checkData : nil)
                            MassBalancePointCards(data: data, result: result, stacked: false)
                            MassBalanceSectionTitle(text: L10n.MassBalance.loadTitle, note: L10n.MassBalance.loadUnits)
                            MassBalanceLoadRows(data: data, empty: basis.empty, result: result, load: $load)
                        }
                        // The way to the first-time steps is there from a blank sheet on, not only once
                        // every row is entered and the verdict itself asks for it.
                        MassBalanceFootnote(registration: registration, basis: basis, confirmedAt: confirmedAt,
                                            onCheckData: canCheckData && !basis.isConfirmed && result.verdict != .notConfirmed
                                                ? checkData : nil)
                    }
                    .padding(isWide ? 20 : 14)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !isWide {
                    // The verdict in one line and a small chart stay on top while the rows scroll, so
                    // the point is seen to move as the fuel changes.
                    VStack(spacing: 8) {
                        MassBalanceVerdictChip(verdict: result.verdict)
                        MassBalanceChart(data: data, result: result, compact: true)
                            .frame(height: 190)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.cockpitBackground)
                }
            }
            // The registration first: a long title is cut at its end, and it must not be the aircraft.
            .navigationTitle("\(registration) · \(L10n.MassBalance.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // It saves as it goes: one Close, on the left.
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { if let onClose { onClose() } else { dismiss() } }
                }
            }
        }
        .onAppear(perform: start)
        .onChange(of: load) { _, new in persist(new) }
        .sheet(isPresented: $showSteps) {
            if let shipped {
                MassBalanceSetupSteps(registration: registration, shipped: shipped) { showSteps = false }
                    .environment(appState)
            }
        }
        .sheet(isPresented: $showOwn) {
            MassBalanceOwnFiguresView(registration: registration) { showOwn = false }
                .environment(appState)
        }
    }

    /// The app's data is checked in the first-time steps; the pilot's own figures in their form.
    private var canCheckData: Bool { basis.source == .pilot || shipped != nil }

    private func checkData() {
        if basis.source == .pilot { showOwn = true } else { showSteps = true }
    }

    private var confirmedAt: Date? {
        let setup = appState.settings.massBalance[registration]
        return basis.source == .shipped ? setup.confirmedAt : setup.ownConfirmedAt
    }

    private func lines(_ result: MassBalanceResult) -> [String] {
        MassBalanceWords.lines(for: result, basis: basis, registration: registration, load: load)
    }

    private func verdict(_ result: MassBalanceResult) -> some View {
        MassBalanceVerdictCard(verdict: result.verdict, lines: lines(result), onTodays: sayTodays,
                               onCheckData: canCheckData ? checkData : nil)
    }

    private func sayTodays() {
        load.isTodays = true
        load.copiedFrom = nil
    }

    // MARK: - The load, kept per aircraft

    /// Last time's load, marked as not today's unless it was prepared today; the pilot's own mass in the
    /// pilot's seat of a first sheet.
    private func start() {
        guard !loaded else { return }
        loaded = true
        let setup = appState.settings.massBalance[registration]
        // A flight's sheet opens with that flight's load; a check of the aircraft alone with the
        // aircraft's. A sheet started from nothing is today's: only a load taken over from an
        // earlier flight has to be said to be.
        var first = (flight != nil ? flight?.load : setup.startingLoad()) ?? MassBalanceLoad(isTodays: true)
        // The pilot's own mass is the one figure a sheet with no seat answered starts with.
        if first.seats.values.allSatisfy({ $0 == .unset }), let own = appState.settings.massBalance.pilotMassKg,
           let seat = data.seatStations.flatMap({ $0.seats ?? [] }).first(where: { $0.role == .pilot }) {
            first.seats[seat.id] = .person(kg: own)
        }
        opened = first
        load = first
    }

    private func persist(_ new: MassBalanceLoad) {
        guard loaded else { return }
        if let opened {
            guard new != opened else { return }
            self.opened = nil
        }
        flight?.onChange(new)
        var setup = appState.settings.massBalance[registration]
        // A sheet left blank is not kept as a load.
        guard setup.lastLoad != new, !(new.isBlank && setup.lastLoad == nil) else { return }
        setup.lastLoad = new
        setup.lastLoadDay = Date()
        appState.settings.massBalance[registration] = setup
        if let seat = data.seatStations.flatMap({ $0.seats ?? [] }).first(where: { $0.role == .pilot }),
           case .person(let kg)? = new.seats[seat.id] {
            appState.settings.massBalance.pilotMassKg = kg
        }
        appState.saveSettings()
    }
}

// MARK: - The verdict

private func verdictColour(_ verdict: MassBalanceVerdict) -> Color {
    switch verdict {
    case .insideLimits: return .aviationGreen
    case .outsideLimits: return .aviationRed
    case .incomplete, .notConfirmed, .lastTimesLoad: return .aviationAmber
    }
}

/// The verdict on the iPad: the word with its shape, then what it means in words.
struct MassBalanceVerdictCard: View {
    let verdict: MassBalanceVerdict
    let lines: [String]
    var onTodays: () -> Void
    var onCheckData: (() -> Void)?
    /// A kept sheet: the words, and no button.
    var isReadOnly = false

    var body: some View {
        let tint = verdictColour(verdict)
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: MassBalanceWords.symbol(verdict))
                .scaledFont(size: 24, weight: .bold, relativeTo: .title2)
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(tint, lineWidth: 3))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(MassBalanceWords.title(verdict))
                    .scaledFont(size: 28, weight: .bold, relativeTo: .title)
                    .foregroundColor(tint)
                    .accessibilityIdentifier("mb.verdict")
                MassBalanceVerdictLines(lines: lines, verdict: verdict, onTodays: onTodays, onCheckData: onCheckData,
                                        isReadOnly: isReadOnly)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint, lineWidth: 2))
        .accessibilityElement(children: .contain)
    }
}

/// The lines under a verdict and the one button it may need.
struct MassBalanceVerdictLines: View {
    let lines: [String]
    let verdict: MassBalanceVerdict
    var onTodays: () -> Void
    var onCheckData: (() -> Void)?
    var isReadOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .scaledFont(size: 17, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isReadOnly {
                EmptyView()
            } else if verdict == .lastTimesLoad {
                Button(L10n.MassBalance.buttonTodays, action: onTodays)
                    .buttonStyle(MassBalanceActionStyle())
                    .padding(.top, 6)
                    .accessibilityIdentifier("mb.todays")
            } else if verdict == .notConfirmed, let onCheckData {
                Button(L10n.MassBalance.buttonCheckData, action: onCheckData)
                    .buttonStyle(MassBalanceActionStyle())
                    .padding(.top, 6)
                    .accessibilityIdentifier("mb.checkData")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The verdict in one line, for the iPhone's pinned header.
struct MassBalanceVerdictChip: View {
    let verdict: MassBalanceVerdict

    var body: some View {
        let tint = verdictColour(verdict)
        HStack(spacing: 10) {
            Image(systemName: MassBalanceWords.symbol(verdict))
                .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(tint, lineWidth: 2.5))
                .accessibilityHidden(true)
            Text(MassBalanceWords.title(verdict))
                .scaledFont(size: 20, weight: .bold, relativeTo: .title3)
                .accessibilityIdentifier("mb.verdict")
            Spacer(minLength: 0)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint, lineWidth: 2))
    }
}

struct MassBalanceActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(size: 17, weight: .bold, relativeTo: .body)
            .foregroundColor(.black)
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.altimeterBlue.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

// MARK: - The three points

struct MassBalancePointCards: View {
    let data: AircraftMassBalance
    let result: MassBalanceResult
    let stacked: Bool

    private func word(_ point: MassBalancePoint) -> String { MassBalanceWords.pointWord(point, in: result) }

    var body: some View {
        // With a row still to enter the figures are a sum so far: no card says inside or outside.
        let judged = result.isComplete
        let cards = [
            (L10n.MassBalance.pointTakeoff, "arrowtriangle.up.fill", result.takeoff, result.takeoff.map(word) ?? ""),
            // No landing figures before the take-off ones are whole: three cards of sums so far say less than one.
            (L10n.MassBalance.pointLanding, "arrowtriangle.down.fill", judged ? result.landing : nil,
             !judged ? "" : result.landing.map { "\(L10n.MassBalance.pointLeft(Int($0.fuelLitres.rounded()))) · \(word($0))" }
                ?? L10n.MassBalance.pointNoTrip),
            (L10n.MassBalance.pointEmptyTanks, "circle", result.emptyTanks, result.emptyTanks.map(word) ?? "")
        ]
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                MassBalancePointCard(title: card.0, symbol: card.1, point: card.2, note: card.3, data: data,
                                     small: !stacked, judged: judged)
            }
        }
    }
}

private struct MassBalancePointCard: View {
    let title: String
    let symbol: String
    let point: MassBalancePoint?
    let note: String
    let data: AircraftMassBalance
    let small: Bool
    let judged: Bool

    var body: some View {
        let isOutside = judged && point?.isInside == false
        let tint: Color = point == nil ? .dimText : isOutside ? .aviationRed : judged ? .primaryText : .secondaryText
        VStack(alignment: .leading, spacing: 3) {
            Label(title.uppercased(), systemImage: symbol)
                .scaledFont(size: small ? 11 : 13, weight: .semibold, relativeTo: .caption)
                .foregroundColor(isOutside ? .aviationRed : .dimText)
            Text(point.map { MassBalanceWords.mass($0.mass, data.units, withKilograms: false) } ?? "—")
                .scaledFont(size: small ? 16 : 22, design: .monospaced, relativeTo: .title3)
                .foregroundColor(tint)
            Text(point.map { MassBalanceWords.arm($0.arm, data.units) } ?? " ")
                .scaledFont(size: small ? 16 : 22, design: .monospaced, relativeTo: .title3)
                .foregroundColor(tint)
            Text(note)
                .scaledFont(size: small ? 12 : 14, relativeTo: .footnote)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(small ? 9 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
        .accessibilityElement(children: .combine)
    }
}

struct MassBalanceSectionTitle: View {
    let text: String
    let note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased())
                .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .footnote)
                .tracking(0.8)
                .foregroundColor(.aviationGold)
            if let note {
                Text(note)
                    .scaledFont(size: 14, relativeTo: .footnote)
                    .foregroundColor(.dimText)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

/// Where the figures come from and what decides: under every sheet, never folded away.
struct MassBalanceFootnote: View {
    let registration: String
    let basis: MassBalanceBasis
    let confirmedAt: Date?
    var onCheckData: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Text(statement + " " + L10n.MassBalance.footDecides)
                .scaledFont(size: 14, relativeTo: .footnote)
                .foregroundColor(.aviationAmber)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onCheckData {
                Button(L10n.MassBalance.buttonCheckData, action: onCheckData)
                    .buttonStyle(MassBalanceActionStyle())
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("mb.checkData")
            }
            ForEach(Array((basis.data.sources ?? []).enumerated()), id: \.offset) { _, source in
                Text([source.document, source.revision.map { "rev. \($0)" }, source.date.map(MassBalanceWords.day)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var statement: String {
        if basis.source == .pilot { return L10n.MassBalance.footYours }
        guard basis.isConfirmed, let confirmedAt else { return L10n.MassBalance.lineNotConfirmed(registration) }
        return L10n.MassBalance.footConfirmed(registration, confirmedAt.formatted(date: .abbreviated, time: .omitted))
    }
}
