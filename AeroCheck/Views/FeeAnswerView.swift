import SwiftUI

/// How the landing fee at one aerodrome was settled: four answers and, for a fee paid or still to be
/// invoiced, the amount in the aerodrome's currency. (6.11.0, the author's f1 and f2)
///
/// One tap answers; the same tap again takes the answer back. The amount is optional and only ever
/// the pilot's: nothing here comes from the app or the server. The line it writes is the flight's own
/// (`FlightCostEntry.fees`), so the flight's page and Flight cost show the same figure, kept once.
struct FeeAnswerView: View {
    let flightId: UUID
    let icao: String
    /// The landings the app counted there, when it could place them.
    var landings: Int?
    /// The currency the amount starts in: the aerodrome's country's, else the flight's.
    var startCurrency: String?
    /// Told after each change, with the answer now on the line (nil when taken back).
    var onAnswered: ((FeeStatus?) -> Void)?

    @Environment(AppState.self) private var appState
    @State private var amountText = ""
    @State private var loadedFor: String?
    @FocusState private var amountFocused: Bool

    private var flight: Flight? { appState.flights.first { $0.id == flightId } }

    private var entry: FlightCostEntry? {
        guard let flight else { return nil }
        if let stored = flight.costEntry { return stored }
        let key = FlightCostCalculator.profileKey(for: flight)
        return FlightCostCalculator.makeEntry(for: flight, profile: key.flatMap { appState.settings.aircraftRates[$0] })
    }

    private var line: FeeItem? { entry?.feeLine(for: icao) }

    private var currency: String {
        if let line, let entry { return entry.currency(of: line) }
        return startCurrency ?? entry?.currency ?? "CHF"
    }

    private var shownLandings: Int? { line?.landings ?? landings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let count = shownLandings, count > 0 {
                Text(L10n.Cost.feeLandings(count))
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(FeeStatus.allCases, id: \.self) { status in
                    answerButton(status)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.Cost.feeAnswerLabel(icao))

            if let status = line?.status, status == .paid || status == .invoice {
                amountRow(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: loadAmount)
        .onChange(of: line?.amount) { _, _ in if !amountFocused { loadAmount(force: true) } }
    }

    private func answerButton(_ status: FeeStatus) -> some View {
        let chosen = line?.status == status
        return Button {
            answer(chosen ? nil : status)
        } label: {
            HStack(spacing: 6) {
                // The tick says "chosen" where colour alone would not.
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 15, relativeTo: .subheadline)
                    .foregroundColor(chosen ? .aviationGreen : .dimText)
                Text(L10n.Cost.feeStatus(status))
                    .scaledFont(size: 14, weight: chosen ? .semibold : .regular, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(chosen ? Color.aviationGreen.opacity(0.7) : Color.white.opacity(0.08), lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("fee.answer.\(icao).\(status.rawValue)")
    }

    private func amountRow(_ status: FeeStatus) -> some View {
        HStack(spacing: 8) {
            Text(status == .paid ? L10n.Cost.feeAmountOptional : L10n.Cost.feeAmountLater)
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Menu {
                ForEach(currencyChoices, id: \.self) { code in
                    Button(code) { save(status: status, currency: code) }
                }
            } label: {
                Text(currency)
                    .scaledFont(size: 14, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.altimeterBlue)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
            }
            .accessibilityLabel(L10n.Cost.currency)
            TextField("—", text: $amountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .scaledFont(size: 16, design: .monospaced, relativeTo: .body)
                .frame(width: 92)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
                .focused($amountFocused)
                .accessibilityLabel(L10n.Cost.feeAmount)
                .accessibilityIdentifier("fee.amount.\(icao)")
                .onChange(of: amountText) { _, _ in if amountFocused { save(status: status, currency: currency) } }
        }
    }

    /// The aerodrome's currency, the flight's, and the two most pilots here pay in.
    private var currencyChoices: [String] {
        var seen = Set<String>()
        return [currency, startCurrency, entry?.currency, "CHF", "EUR", "GBP"]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Writing

    private func loadAmount() { loadAmount(force: false) }

    private func loadAmount(force: Bool) {
        guard force || loadedFor != icao else { return }
        loadedFor = icao
        if let line, line.hasAmount ?? true, line.amount > 0 {
            amountText = line.amount == line.amount.rounded() ? String(Int(line.amount)) : String(line.amount)
        } else {
            amountText = ""
        }
    }

    /// Both separators: a Swiss tariff page writes 23,50 and 19.50 in the same table.
    private var typedAmount: Double? {
        let cleaned = amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func answer(_ status: FeeStatus?) {
        guard let flight, var entry else { return }
        if let status {
            let keepsAmount = status == .paid || status == .invoice
            entry.settleFee(at: icao, label: L10n.Cost.landingFee(icao.uppercased()), status: status,
                            amount: keepsAmount ? typedAmount : nil, currency: currency,
                            landings: shownLandings, at: Date())
            if !keepsAmount { amountText = "" }
        } else {
            entry.clearFee(at: icao)
            amountText = ""
        }
        appState.updateFlightCost(flight, cost: entry)
        onAnswered?(status)
    }

    private func save(status: FeeStatus, currency: String) {
        guard let flight, var entry else { return }
        entry.settleFee(at: icao, label: L10n.Cost.landingFee(icao.uppercased()), status: status,
                        amount: typedAmount, currency: currency, landings: shownLandings, at: Date())
        appState.updateFlightCost(flight, cost: entry)
    }
}
