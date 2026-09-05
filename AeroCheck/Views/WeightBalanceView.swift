import SwiftUI

/// Mass & balance for one aircraft. Every figure is the pilot's: empty mass and arm from the
/// aircraft's weighing report, station arms and the envelope from its AFM.
///
/// The app ships none of that data on purpose. Empty mass is per registration and changes whenever
/// the aircraft is modified or re-weighed, and an envelope belongs to a specific variant — shipping
/// a plausible one that turns out to be the wrong model is exactly the error a pilot cannot catch by
/// eye. So the app owns the arithmetic and the pilot owns the inputs, and the verdict says
/// "unknown" rather than "fine" whenever an envelope has not been entered.
struct WeightBalanceView: View {
    /// Registration this profile belongs to; empty mass is per tail, never per type.
    let registration: String
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft = WeightBalanceProfile()
    @State private var loaded = false
    @State private var showSetup = false

    private var result: WeightBalanceResult { WeightBalanceCalculator.compute(profile: draft) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        if draft.isConfigured {
                            verdictCard
                            stationsCard
                            setupCard
                        } else {
                            notConfiguredCard
                        }
                        Text(L10n.WeightBalance.advisory)
                            .scaledFont(size: 11, relativeTo: .caption2)
                            .foregroundColor(.aviationAmber.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("\(L10n.WeightBalance.title) · \(registration)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Button.close) { persist(); close() }
                }
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showSetup) {
            WeightBalanceSetupSheet(profile: draft) { updated in
                draft = updated
                persist()
                showSetup = false
            } onCancel: {
                showSetup = false
            }
        }
    }

    // MARK: - Cards

    private var verdictCard: some View {
        let verdict = result.isWithinLimits
        let tint: Color = verdict == true ? .aviationGreen : (verdict == false ? .aviationRed : .aviationAmber)

        return VStack(spacing: 12) {
            HStack(spacing: 20) {
                metric(L10n.WeightBalance.totalWeight,
                       value: String(format: "%.0f kg", result.totalWeightKg),
                       tint: result.isOverweight ? .aviationRed : .primaryText)
                metric(L10n.WeightBalance.centreOfGravity,
                       value: result.centreOfGravityMeters.map { String(format: "%.3f m", $0) } ?? "—",
                       tint: .primaryText)
                metric(L10n.WeightBalance.remainingPayload,
                       value: String(format: "%.0f kg", result.remainingPayloadKg),
                       tint: .secondaryText)
            }

            Text(verdictText)
                .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                .foregroundColor(tint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.45), lineWidth: 1.5))
    }

    private var verdictText: String {
        if result.isOverweight { return L10n.WeightBalance.overweight }
        switch result.isInsideEnvelope {
        case .some(true):  return L10n.WeightBalance.insideEnvelope
        case .some(false): return L10n.WeightBalance.outsideEnvelope
        case .none:        return L10n.WeightBalance.envelopeUnknown
        }
    }

    private func metric(_ label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                .foregroundColor(.dimText)
                .tracking(0.5)
            Text(value)
                .scaledFont(size: 17, weight: .bold, design: .monospaced, relativeTo: .title3)
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity)
    }

    private var stationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(L10n.WeightBalance.stations, tint: .aviationGold)
            VStack(spacing: 0) {
                stationRow(name: L10n.WeightBalance.emptyWeight,
                           arm: draft.emptyArmMeters,
                           weight: Binding(get: { draft.emptyWeightKg }, set: { draft.emptyWeightKg = $0 }),
                           editable: false)
                ForEach($draft.stations) { $station in
                    Divider().overlay(Color.white.opacity(0.06))
                    stationRow(name: station.name,
                               arm: station.armMeters,
                               weight: $station.weightKg,
                               editable: true)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .onChange(of: draft) { _, _ in persist() }
    }

    private func stationRow(name: String, arm: Double, weight: Binding<Double>, editable: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .scaledFont(size: 13, weight: .medium, relativeTo: .footnote)
                    .foregroundColor(.primaryText)
                Text(String(format: "%.3f m", arm))
                    .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.dimText)
            }
            Spacer(minLength: 8)
            if editable {
                TextField("0", value: weight, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .scaledFont(size: 15, design: .monospaced, relativeTo: .subheadline)
                    .frame(width: 78)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
            } else {
                Text(String(format: "%.0f", weight.wrappedValue))
                    .scaledFont(size: 15, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                    .frame(width: 78, alignment: .trailing)
            }
            Text("kg")
                .scaledFont(size: 11, relativeTo: .caption2)
                .foregroundColor(.dimText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var setupCard: some View {
        Button { showSetup = true } label: {
            HStack {
                Text(L10n.WeightBalance.setup)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.altimeterBlue)
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
            }
            .padding(14)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var notConfiguredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "scalemass")
                .scaledFont(size: 30, relativeTo: .largeTitle)
                .foregroundColor(.aviationGold)
            Text(L10n.WeightBalance.notConfigured)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.primaryText)
                .multilineTextAlignment(.center)
            Text(L10n.WeightBalance.fromWeighingReport)
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.WeightBalance.setup) { showSetup = true }
                .buttonStyle(PrimaryButtonStyle(color: .aviationGold))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func header(_ title: String, tint: Color) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
            .foregroundColor(tint)
            .tracking(0.8)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panelBackground)
    }

    // MARK: - Persistence

    private func load() {
        guard !loaded else { return }
        draft = appState.settings.weightBalanceProfiles[registration] ?? WeightBalanceProfile()
        loaded = true
    }

    private func persist() {
        guard loaded else { return }
        appState.settings.weightBalanceProfiles[registration] = draft
        appState.saveSettings()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

// MARK: - Setup sheet

/// The per-aircraft figures: empty mass and arm, MTOW, the stations and (optionally) the envelope.
private struct WeightBalanceSetupSheet: View {
    @State var profile: WeightBalanceProfile
    let onSave: (WeightBalanceProfile) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.WeightBalance.fromWeighingReport)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            numberField(L10n.WeightBalance.emptyWeight, unit: "kg", value: $profile.emptyWeightKg)
                            numberField(L10n.WeightBalance.emptyArm, unit: "m", value: $profile.emptyArmMeters, decimals: true)
                        }
                        numberField(L10n.WeightBalance.mtow, unit: "kg", value: $profile.maxTakeoffWeightKg)

                        stationsEditor
                        envelopeEditor
                    }
                    .padding(20)
                    .frame(maxWidth: 560)
                }
            }
            .navigationTitle(L10n.WeightBalance.setup)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.Button.cancel) { onCancel() } }
                ToolbarItem(placement: .topBarTrailing) { Button(L10n.Button.done) { onSave(profile) } }
            }
        }
    }

    private var stationsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.WeightBalance.stations)
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .foregroundColor(.dimText)

            ForEach($profile.stations) { $station in
                HStack(spacing: 8) {
                    TextField(L10n.WeightBalance.stationName, text: $station.name)
                        .scaledFont(size: 14, relativeTo: .subheadline)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
                    TextField("0.000", value: $station.armMeters, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                        .frame(width: 80)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
                    Text("m").scaledFont(size: 11, relativeTo: .caption2).foregroundColor(.dimText)
                    Button {
                        profile.stations.removeAll { $0.id == station.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.aviationRed.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                profile.stations.append(WeightBalanceStation(name: "", armMeters: 0, weightKg: 0))
            } label: {
                Label(L10n.WeightBalance.addStation, systemImage: "plus.circle")
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.altimeterBlue)
            }
            .buttonStyle(.plain)
        }
    }

    private var envelopeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.WeightBalance.envelope)
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .foregroundColor(.dimText)
            Text(L10n.WeightBalance.envelopeHint)
                .scaledFont(size: 11, relativeTo: .caption2)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array((profile.envelope ?? []).enumerated()), id: \.offset) { index, point in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.dimText)
                        .frame(width: 18)
                    TextField("arm", value: Binding(
                        get: { point.armMeters },
                        set: { profile.envelope?[index].armMeters = $0 }
                    ), format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
                    TextField("kg", value: Binding(
                        get: { point.weightKg },
                        set: { profile.envelope?[index].weightKg = $0 }
                    ), format: .number)
                        .keyboardType(.decimalPad)
                        .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
                    Button {
                        profile.envelope?.remove(at: index)
                        if profile.envelope?.isEmpty == true { profile.envelope = nil }
                    } label: {
                        Image(systemName: "minus.circle").foregroundColor(.aviationRed.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                profile.envelope = (profile.envelope ?? []) + [EnvelopePoint(armMeters: 0, weightKg: 0)]
            } label: {
                Label(L10n.WeightBalance.addEnvelopePoint, systemImage: "plus.circle")
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.altimeterBlue)
            }
            .buttonStyle(.plain)
        }
    }

    private func numberField(_ label: String, unit: String, value: Binding<Double>, decimals: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(label) (\(unit))")
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .foregroundColor(.dimText)
            TextField("0", value: value, format: .number)
                .keyboardType(decimals ? .numbersAndPunctuation : .decimalPad)
                .scaledFont(size: 16, design: .monospaced, relativeTo: .body)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
        }
    }
}
