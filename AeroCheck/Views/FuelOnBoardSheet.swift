import SwiftUI

// MARK: - Fuel on board (on-device review #4, point 3)
//
// The flight's Fuel plan task used to send the pilot to the whole nav log sheet to type one number.
// A tap on the task now opens this sheet: what's required, what's on board, and one tap for full
// tanks. The nav log sheet ("Fuel & times") stays one link away for the rest.

/// Usable fuel with full tanks for one registration, and where the figure comes from.
struct FullTanks: Equatable {
    enum Source: Equatable {
        /// The aircraft's checklist data, through the server (`usableFuelLitres`).
        case aircraftData
        /// What the pilot entered for this registration, kept in the settings.
        case pilot
    }

    let litres: Double
    let source: Source

    /// The aircraft's data wins; otherwise the pilot's figure for this registration; otherwise nil,
    /// and the sheet asks for it.
    static func resolve(registration: String?, available: [RemoteAircraftMetadata],
                        pilotValues: [String: Double]) -> FullTanks? {
        guard let key = key(for: registration) else { return nil }
        if let litres = available.first(where: { $0.registration.uppercased() == key })?.usableFuelLitres,
           isPlausible(litres) {
            return FullTanks(litres: litres, source: .aircraftData)
        }
        if let litres = pilotValues[key], isPlausible(litres) {
            return FullTanks(litres: litres, source: .pilot)
        }
        return nil
    }

    /// The settings key for a registration: trimmed and upper-cased, nil when there's none.
    static func key(for registration: String?) -> String? {
        guard let reg = registration?.trimmingCharacters(in: .whitespaces).uppercased(), !reg.isEmpty
        else { return nil }
        return reg
    }

    /// No light aircraft tank is empty or holds 2,000 L; a figure outside that is a typo.
    static func isPlausible(_ litres: Double) -> Bool { litres.isFinite && litres > 0 && litres <= 2000 }
}

/// Fuel on board against what's required.
enum FuelOnBoardStatus: Equatable {
    case notSet
    /// On board covers the required fuel, with this margin (litres, and minutes at the fuel flow).
    case enough(marginLitres: Double, minutes: Int)
    case short(litres: Double)

    static func make(onBoard: Double?, required: Double?, flowLitresPerHour: Double) -> FuelOnBoardStatus {
        guard let onBoard, onBoard > 0, let required else { return .notSet }
        let margin = onBoard - required
        guard margin >= 0 else { return .short(litres: -margin) }
        let minutes = flowLitresPerHour > 0 ? Int((margin / flowLitresPerHour * 60).rounded(.down)) : 0
        return .enough(marginLitres: margin, minutes: minutes)
    }

    /// More on board than the tanks hold: a typo, or the wrong full-tanks figure.
    static func exceedsFullTanks(onBoard: Double?, fullTanks: Double?) -> Bool {
        guard let onBoard, let fullTanks else { return false }
        return onBoard > fullTanks + 0.05
    }
}

/// Litres as typed: "60", "60.5" or "60,5". Nil for an empty or unreadable entry.
enum FuelEntry {
    static func litres(from text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// One decimal at most, none when whole: "60", "60.5".
    static func text(_ litres: Double) -> String {
        litres.rounded() == litres ? String(Int(litres)) : String(format: "%.1f", litres)
    }
}

// MARK: - The sheet

struct FuelOnBoardSheet: View {
    let planId: UUID
    /// "Fuel & times": the nav log sheet, for the fuel flow, reserves and extra.
    var onOpenFullEditor: (() -> Void)?

    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var onBoardText = ""
    @FocusState private var focus: Field?

    private enum Field { case onBoard }

    private var plan: FlightPlan? { flightPlanManager.flightPlans.first { $0.id == planId } }
    private var onBoard: Double? { FuelEntry.litres(from: onBoardText) }
    private var fullTanks: FullTanks? {
        FullTanks.resolve(registration: plan?.aircraftRegistration,
                          available: aircraftDataService.availableAircraft,
                          pilotValues: appState.settings.fullTanksLitres)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let plan {
                    VStack(alignment: .leading, spacing: 14) {
                        requiredCard(plan)
                        onBoardCard(plan)
                        statusLine(plan)
                        if onOpenFullEditor != nil {
                            Button {
                                save()
                                onOpenFullEditor?()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(L10n.FuelOnBoard.moreFuelSettings)
                                    Image(systemName: "chevron.right")
                                        .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                                }
                                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                                .foregroundColor(.altimeterBlue)
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle(L10n.FuelOnBoard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Button.done) {
                        save()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .onAppear {
            // Not focused on open: on the iPad the number pad would cover the required fuel, which is
            // what the pilot reads first. Full tanks and = Required need no keyboard at all.
            if let fob = plan?.fuelOnBoard, fob > 0 { onBoardText = FuelEntry.text(fob) }
        }
    }

    // MARK: Required

    private func requiredCard(_ plan: FlightPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cardTitle(L10n.FuelOnBoard.required)
            if let required = plan.fuelRequired {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", required))
                        .scaledFont(size: 34, weight: .bold, design: .monospaced, relativeTo: .largeTitle)
                        .foregroundColor(.primaryText)
                    Text("L")
                        .scaledFont(size: 17, relativeTo: .body)
                        .foregroundColor(.secondaryText)
                }
                // What it adds up to, so the figure can be checked at a glance.
                Text(L10n.FuelOnBoard.breakdown(
                    String(format: "%.1f", plan.tripFuel ?? 0),
                    String(format: "%.1f", plan.reserveFuel ?? 0),
                    String(format: "%.1f", plan.finalReserveFuel),
                    String(format: "%.1f", plan.extraFuel ?? 0)))
                    .scaledFont(size: 13, design: .monospaced, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.FuelOnBoard.noRequired)
                    .scaledFont(size: 15, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
    }

    // MARK: On board

    private func onBoardCard(_ plan: FlightPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle(L10n.FuelOnBoard.onBoard)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $onBoardText)
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .onBoard)
                    .scaledFont(size: 34, weight: .bold, design: .monospaced, relativeTo: .largeTitle)
                    .foregroundColor(.primaryText)
                    .accessibilityLabel(L10n.FuelOnBoard.onBoard)
                Text("L")
                    .scaledFont(size: 17, relativeTo: .body)
                    .foregroundColor(.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.aviationGold.opacity(0.7), lineWidth: 1.5))

            if FullTanks.key(for: plan.aircraftRegistration) != nil {
                fullTanksControls(plan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
    }

    private func fullTanksControls(_ plan: FlightPlan) -> some View {
        FullTanksButtons(registration: plan.aircraftRegistration, required: plan.fuelRequired) { litres in
            onBoardText = FuelEntry.text(litres)
            focus = nil
        }
    }

    // MARK: Status

    @ViewBuilder
    private func statusLine(_ plan: FlightPlan) -> some View {
        let status = FuelOnBoardStatus.make(onBoard: onBoard, required: plan.fuelRequired,
                                            flowLitresPerHour: plan.effectiveFuelFlow)
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .notSet:
                statusText(L10n.FuelOnBoard.notSet, icon: "fuelpump", color: .dimText)
            case .enough(let margin, let minutes):
                statusText(L10n.FuelOnBoard.enough(String(format: "%.1f", margin), String(minutes),
                                                   FuelEntry.text(plan.effectiveFuelFlow)),
                           icon: "checkmark.circle.fill", color: .aviationGreen)
            case .short(let litres):
                statusText(L10n.FuelOnBoard.short(String(format: "%.1f", litres)),
                           icon: "exclamationmark.triangle.fill", color: .aviationAmber)
            }
            if FuelOnBoardStatus.exceedsFullTanks(onBoard: onBoard, fullTanks: fullTanks?.litres),
               let fullTanks {
                statusText(L10n.FuelOnBoard.overFullTanks(FuelEntry.text(fullTanks.litres)),
                           icon: "exclamationmark.triangle.fill", color: .aviationAmber)
            }
        }
        .padding(.horizontal, 4)
    }

    private func statusText(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption)
            .foregroundColor(.aviationGold)
            .tracking(0.8)
    }

    // MARK: Saving

    private func save() {
        guard var plan else { return }
        // An empty field clears fuel on board; an unreadable one changes nothing.
        let trimmed = onBoardText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            guard plan.fuelOnBoard != nil else { return }
            plan.fuelOnBoard = nil
        } else {
            guard let litres = FuelEntry.litres(from: trimmed), litres != plan.fuelOnBoard else { return }
            plan.fuelOnBoard = litres
        }
        flightPlanManager.updateFlightPlan(plan)
    }
}

// MARK: - Full tanks and = Required

/// The two one-tap fills for fuel on board: Full tanks (the aircraft's figure, or the pilot's, asked
/// for once when there's none) and = Required (rounded up to the litre). Shared by the fuel sheet
/// and the flight sheet's fuel ledger. (on-device review #4, point 3; planning proposal A2)
struct FullTanksButtons: View {
    let registration: String
    let required: Double?
    let onFill: (Double) -> Void

    @Environment(AppState.self) private var appState
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @State private var fullTanksText = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var fullTanks: FullTanks? {
        FullTanks.resolve(registration: registration, available: aircraftDataService.availableAircraft,
                          pilotValues: appState.settings.fullTanksLitres)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let fullTanks, !editing {
                    fillButton(L10n.FuelOnBoard.fullTanks(FuelEntry.text(fullTanks.litres)), icon: "fuelpump.fill") {
                        onFill(fullTanks.litres)
                    }
                }
                if let required, required > 0 {
                    fillButton(L10n.FuelOnBoard.equalsRequired(FuelEntry.text(required.rounded(.up))), icon: "equal") {
                        onFill(required.rounded(.up))
                    }
                }
            }
            if FullTanks.key(for: registration) != nil {
                if let fullTanks, !editing {
                    HStack(spacing: 8) {
                        Text(fullTanks.source == .aircraftData
                             ? L10n.FuelOnBoard.fromAircraftData
                             : L10n.FuelOnBoard.yourFigure(registration))
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                        if fullTanks.source == .pilot {
                            Button(L10n.FuelOnBoard.change) {
                                fullTanksText = FuelEntry.text(fullTanks.litres)
                                editing = true
                                focused = true
                            }
                            .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                            .foregroundColor(.altimeterBlue)
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    askForFullTanks
                }
            }
        }
    }

    /// No figure yet, or changing the pilot's: ask for it once, keep it for this tail.
    private var askForFullTanks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.FuelOnBoard.fullTanksPrompt(registration))
                .scaledFont(size: 13, relativeTo: .caption)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    TextField("—", text: $fullTanksText)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .scaledFont(size: 18, weight: .semibold, design: .monospaced, relativeTo: .body)
                        .accessibilityLabel(L10n.FuelOnBoard.fullTanksPrompt(registration))
                    Text("L").foregroundColor(.secondaryText)
                }
                .padding(.horizontal, 12)
                .frame(width: 130, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.cockpitBackground.opacity(0.6)))
                Button(L10n.FuelOnBoard.saveAndFill) { save() }
                    .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .disabled(!(FuelEntry.litres(from: fullTanksText).map(FullTanks.isPlausible) ?? false))
                if editing {
                    Button(L10n.Button.cancel) { editing = false }
                        .scaledFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(.secondaryText)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func fillButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                .foregroundColor(.aviationGold)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationGold.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.aviationGold.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard let key = FullTanks.key(for: registration),
              let litres = FuelEntry.litres(from: fullTanksText), FullTanks.isPlausible(litres) else { return }
        appState.settings.fullTanksLitres[key] = litres
        appState.saveSettings()
        editing = false
        onFill(litres)
    }
}

