import SwiftUI
import UIKit

/// What a flight cost, and the logbook line it produces. The close-out half of the Flight Thread,
/// reachable from a thread's CLOSE chapter and from any flight in the Flight Log.
///
/// The rate is edited here rather than buried in Settings: the moment you need it is the moment you
/// are recording a flight, and a club rate is a thing you set once per aircraft and forget.
struct FlightNumbersView: View {
    let flightId: UUID
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showRateEditor = false
    @State private var rateText = ""
    @State private var basis: BillingBasis = .block
    @State private var currency = "CHF"
    @State private var newFeeLabel = ""
    @State private var newFeeAmount = ""
    @State private var showLogbookEditor = false
    @State private var exportedCSV: Data?
    @State private var csvFilename = "logbook.csv"
    /// Registration whose mass & balance is open. (v5.0.0)
    @State private var weightBalanceRegistration: String?

    private var flight: Flight? { appState.flights.first { $0.id == flightId } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                if let flight {
                    ScrollView {
                        VStack(spacing: 16) {
                            costSection(flight)
                            logbookSection(flight)
                            massBalanceSection(flight)
                        }
                        .padding(20)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Text(L10n.Thread.noThread)
                        .foregroundColor(.secondaryText)
                }
            }
            .navigationTitle(L10n.Cost.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Button.close) { close() }
                }
            }
        }
        // Reuses the Flight Log's ShareSheet/ShareFile pair rather than writing a temp file:
        // ShareFile hands UIActivityViewController the bytes with a filename and a UTI directly.
        .sheet(isPresented: Binding(
            get: { weightBalanceRegistration != nil },
            set: { if !$0 { weightBalanceRegistration = nil } }
        )) {
            if let registration = weightBalanceRegistration {
                WeightBalanceView(registration: registration,
                                  onClose: { weightBalanceRegistration = nil })
                    .environment(appState)
            }
        }
        .sheet(isPresented: Binding(
            get: { exportedCSV != nil },
            set: { if !$0 { exportedCSV = nil } }
        )) {
            if let data = exportedCSV {
                ShareSheet(activityItems: [
                    ShareFile(data: data,
                              filename: csvFilename,
                              dataTypeIdentifier: "public.comma-separated-values-text")
                ])
            }
        }
    }

    // MARK: - Cost

    @ViewBuilder
    private func costSection(_ flight: Flight) -> some View {
        let profile = rateProfile(for: flight)
        let entry = flight.costEntry ?? FlightCostCalculator.makeEntry(for: flight, profile: profile)

        card(title: L10n.Cost.title.uppercased(), tint: .aviationGold) {
            if profile == nil && flight.costEntry == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.Cost.noRateSet)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                    Button(L10n.Cost.setRate) { beginRateEdit(flight) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                VStack(spacing: 10) {
                    if let rate = entry.hourlyRate, let hours = entry.billedHours {
                        row(
                            "\(FlightCostCalculator.formatAmount(rate, currency: entry.currency))/h · \(entry.basis?.label ?? "") · \(String(format: "%.1f", hours)) h",
                            value: FlightCostCalculator.formatAmount(entry.aircraftCost, currency: entry.currency)
                        )
                    } else if entry.hourlyRate != nil {
                        // Rate known but the basis was never recorded on this flight.
                        Text(L10n.Cost.notRecorded)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.aviationAmber)
                    }

                    ForEach(entry.fees) { fee in
                        row(fee.label, value: FlightCostCalculator.formatAmount(fee.amount, currency: entry.currency)) {
                            removeFee(fee, from: flight)
                        }
                    }

                    addFeeRow(flight)

                    Divider().overlay(Color.white.opacity(0.08))
                    row(L10n.Cost.total,
                        value: FlightCostCalculator.formatAmount(entry.total, currency: entry.currency),
                        emphasised: true)

                    Button(L10n.Cost.setRate) { beginRateEdit(flight) }
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.altimeterBlue)
                        .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showRateEditor) { rateEditor(flight) }
    }

    private func addFeeRow(_ flight: Flight) -> some View {
        HStack(spacing: 8) {
            TextField(L10n.Cost.feeLabel, text: $newFeeLabel)
                .textFieldStyle(.plain)
                .scaledFont(size: 13, relativeTo: .footnote)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
            TextField(L10n.Cost.feeAmount, text: $newFeeAmount)
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .scaledFont(size: 13, design: .monospaced, relativeTo: .footnote)
                .frame(width: 80)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
            Button {
                addFee(to: flight)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .scaledFont(size: 20, relativeTo: .title3)
                    .foregroundColor(canAddFee ? .aviationGreen : .dimText.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canAddFee)
            .accessibilityLabel(L10n.Cost.addFee)
        }
    }

    private var canAddFee: Bool {
        !newFeeLabel.trimmingCharacters(in: .whitespaces).isEmpty && parseAmount(newFeeAmount) != nil
    }

    private func rateEditor(_ flight: Flight) -> some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.Cost.rateProfilesHint)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)

                    HStack(spacing: 10) {
                        TextField(L10n.Cost.hourlyRate, text: $rateText)
                            .keyboardType(.decimalPad)
                            .scaledFont(size: 17, design: .monospaced, relativeTo: .body)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
                        TextField(L10n.Cost.currency, text: $currency)
                            .scaledFont(size: 17, design: .monospaced, relativeTo: .body)
                            .frame(width: 80)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.Cost.billingBasis)
                            .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                            .foregroundColor(.dimText)
                        Picker(L10n.Cost.billingBasis, selection: $basis) {
                            ForEach(BillingBasis.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: 520)
            }
            .navigationTitle(L10n.Cost.rateProfiles)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Button.cancel) { showRateEditor = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Button.done) { saveRate(for: flight) }
                        .disabled(parseAmount(rateText) == nil)
                }
            }
        }
    }

    // MARK: - Logbook

    @ViewBuilder
    private func logbookSection(_ flight: Flight) -> some View {
        let line = LogbookLineBuilder.build(flight: flight,
                                            overrides: flight.logbook,
                                            defaultPilotName: appState.settings.pilotName)

        card(title: L10n.Logbook.title.uppercased(), tint: .altimeterBlue) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Logbook.subtitle)
                    .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.dimText)

                VStack(spacing: 4) {
                    ForEach(Array(zip(LogbookLine.csvHeader, line.csvRow)), id: \.0) { column, value in
                        if !value.isEmpty {
                            row(column, value: value, mono: true)
                        }
                    }
                }

                Text(L10n.Logbook.timesAreUTC)
                    .scaledFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(.dimText)
                Text(L10n.Logbook.nightNotComputed)
                    .scaledFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(L10n.Logbook.copyLine) {
                        UIPasteboard.general.string = LogbookLineBuilder.plainText(for: line)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button(L10n.Logbook.exportCSV) { exportCSV(line, flight: flight) }
                        .buttonStyle(SecondaryButtonStyle())

                    Button(L10n.Nav.edit) { showLogbookEditor = true }
                        .buttonStyle(SecondaryButtonStyle())
                }

                Text(L10n.Logbook.notALogbook)
                    .scaledFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(.aviationAmber.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showLogbookEditor) { logbookEditor(flight) }
    }

    private func logbookEditor(_ flight: Flight) -> some View {
        LogbookOverridesEditor(
            overrides: flight.logbook ?? LogbookOverrides(),
            onSave: { updated in
                appState.updateFlightLogbook(flight, overrides: updated)
                showLogbookEditor = false
            },
            onCancel: { showLogbookEditor = false }
        )
    }

    // MARK: - Mass & balance

    /// The mass & balance calculator for this flight's aircraft.
    ///
    /// Here rather than in the Flight Log's action row for two reasons: that row is already five
    /// controls wide on an iPhone, and the profile is per AIRCRAFT rather than per flight — reaching
    /// it from a past flight is really "set up or check this tail", which is exactly what a pilot
    /// wants the evening before the next one. Without a thread there was previously no way in at all.
    @ViewBuilder
    private func massBalanceSection(_ flight: Flight) -> some View {
        card(title: L10n.WeightBalance.title.uppercased(), tint: .aviationGold) {
            if let registration = flight.aircraftRegistration, !registration.isEmpty {
                let profile = appState.settings.weightBalanceProfiles[registration]
                Button { weightBalanceRegistration = registration } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(registration)
                                .scaledFont(size: 14, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                            Text(profile?.isConfigured == true
                                 ? L10n.WeightBalance.setup
                                 : L10n.WeightBalance.notConfigured)
                                .scaledFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.dimText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                            .foregroundColor(.dimText.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // The profile is keyed by registration, so a flight recorded without one has no
                // aircraft to open. Say that rather than offering a button that cannot work.
                Text(L10n.WeightBalance.notConfigured)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
            }
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(tint)
                .tracking(0.8)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panelBackground)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(14)
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func row(_ label: String, value: String, emphasised: Bool = false,
                     mono: Bool = false, onDelete: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .scaledFont(size: mono ? 11 : 13, relativeTo: .footnote)
                .foregroundColor(emphasised ? .primaryText : .secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .scaledFont(size: emphasised ? 15 : 13, weight: emphasised ? .bold : .regular,
                            design: .monospaced, relativeTo: .footnote)
                .foregroundColor(emphasised ? .aviationGold : .primaryText)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .scaledFont(size: 14, relativeTo: .footnote)
                        .foregroundColor(.aviationRed.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Button.delete)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Actions

    private func rateProfile(for flight: Flight) -> AircraftRateProfile? {
        guard let key = FlightCostCalculator.profileKey(for: flight) else { return nil }
        return appState.settings.aircraftRates[key]
    }

    private func beginRateEdit(_ flight: Flight) {
        let existing = rateProfile(for: flight)
        rateText = existing.map { String(format: "%g", $0.hourlyRate) } ?? ""
        currency = existing?.currency ?? "CHF"
        basis = existing?.basis ?? .block
        showRateEditor = true
    }

    private func saveRate(for flight: Flight) {
        guard let rate = parseAmount(rateText),
              let key = FlightCostCalculator.profileKey(for: flight) else { return }
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespaces)
        let profile = AircraftRateProfile(hourlyRate: rate,
                                          currency: trimmedCurrency.isEmpty ? "CHF" : trimmedCurrency,
                                          basis: basis)
        appState.settings.aircraftRates[key] = profile
        appState.saveSettings()

        // Re-snapshot this flight's cost from the new rate, keeping any fees already entered. The
        // snapshot is what stops a future rate change from silently rewriting a past flight.
        var entry = FlightCostCalculator.makeEntry(for: flight, profile: profile)
        entry.fees = flight.costEntry?.fees ?? []
        entry.note = flight.costEntry?.note
        appState.updateFlightCost(flight, cost: entry)
        showRateEditor = false
    }

    private func addFee(to flight: Flight) {
        guard let amount = parseAmount(newFeeAmount) else { return }
        var entry = flight.costEntry ?? FlightCostCalculator.makeEntry(for: flight, profile: rateProfile(for: flight))
        entry.fees.append(FeeItem(label: newFeeLabel.trimmingCharacters(in: .whitespaces), amount: amount))
        appState.updateFlightCost(flight, cost: entry)
        newFeeLabel = ""
        newFeeAmount = ""
    }

    private func removeFee(_ fee: FeeItem, from flight: Flight) {
        guard var entry = flight.costEntry else { return }
        entry.fees.removeAll { $0.id == fee.id }
        appState.updateFlightCost(flight, cost: entry)
    }

    /// Accepts both decimal separators — a Swiss tariff page writes CHF 23,50 and CHF 19.50 in the
    /// same table, so a pilot copying a figure will type either.
    private func parseAmount(_ text: String) -> Double? {
        let normalised = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalised), value >= 0, value.isFinite else { return nil }
        return value
    }

    private func exportCSV(_ line: LogbookLine, flight: Flight) {
        csvFilename = "AeroCheck_logbook_"
            + LogbookLineBuilder.formatDate(flight.blockOffTime ?? flight.startTime)
                .replacingOccurrences(of: ".", with: "-")
            + ".csv"
        exportedCSV = Data(LogbookLineBuilder.csv(for: [line]).utf8)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

}

// MARK: - Logbook overrides editor

/// The columns the app cannot derive: function time, night, IFR and remarks.
private struct LogbookOverridesEditor: View {
    @State var overrides: LogbookOverrides
    let onSave: (LogbookOverrides) -> Void
    let onCancel: () -> Void

    @State private var nightText = ""
    @State private var ifrText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        field(L10n.Logbook.picName, text: Binding(
                            get: { overrides.picName ?? "" },
                            set: { overrides.picName = $0.isEmpty ? nil : $0 }
                        ))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.Logbook.function)
                                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                                .foregroundColor(.dimText)
                            Picker(L10n.Logbook.function, selection: Binding(
                                get: { overrides.function ?? .pic },
                                set: { overrides.function = $0 }
                            )) {
                                ForEach(LogbookFunction.allCases, id: \.self) { function in
                                    Text(LogbookLineBuilder.label(for: function)).tag(function)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack(spacing: 12) {
                            minutesField(L10n.Logbook.nightTime, text: $nightText)
                            minutesField(L10n.Logbook.ifrTime, text: $ifrText)
                        }
                        Text(L10n.Logbook.nightNotComputed)
                            .scaledFont(size: 11, relativeTo: .caption2)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)

                        field(L10n.Logbook.remarks, text: Binding(
                            get: { overrides.remarks ?? "" },
                            set: { overrides.remarks = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    .padding(20)
                    .frame(maxWidth: 520)
                }
            }
            .navigationTitle(L10n.Logbook.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Button.cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Button.done) {
                        overrides.nightMinutes = Int(nightText)
                        overrides.ifrMinutes = Int(ifrText)
                        onSave(overrides)
                    }
                }
            }
            .onAppear {
                nightText = overrides.nightMinutes.map(String.init) ?? ""
                ifrText = overrides.ifrMinutes.map(String.init) ?? ""
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .foregroundColor(.dimText)
            TextField(label, text: text)
                .scaledFont(size: 15, relativeTo: .subheadline)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
        }
    }

    private func minutesField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(label) (min)")
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .foregroundColor(.dimText)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .scaledFont(size: 15, design: .monospaced, relativeTo: .subheadline)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
        }
    }
}
