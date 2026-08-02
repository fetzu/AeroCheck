import SwiftUI

/// Post-flight review diff (decision D2): what the track shows vs what was confirmed in
/// flight. Presented once, right after END FLIGHT, only when the offline re-segmentation
/// (`FlightReconciliation`) found something the in-flight confirmations missed — a
/// touch-and-go whose prompt auto-dismissed in the circuit, a landing lost to an early
/// recording stop, a type the <15 ft ambiguity band couldn't decide.
///
/// One tap applies the track's reading; each row's type can be overridden (TG ↔ GA ↔ FS)
/// and detected-only rows can be excluded; "keep as recorded" leaves the logbook exactly
/// as confirmed. Confirmed events are never changed silently — that is the whole point.
struct FlightReconciliationView: View {
    let result: FlightReconciliation.Result
    let onApply: (FlightReconciliation.Result) -> Void
    let onKeep: () -> Void

    @State private var rows: [FlightReconciliation.EventRow]

    init(result: FlightReconciliation.Result,
         onApply: @escaping (FlightReconciliation.Result) -> Void,
         onKeep: @escaping () -> Void) {
        self.result = result
        self.onApply = onApply
        self.onKeep = onKeep
        _rows = State(initialValue: result.events)
    }

    private var landingsDetected: Int { rows.filter { $0.type != .goAround }.count }
    private var goAroundsDetected: Int { rows.filter { $0.type == .goAround }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($rows) { $row in
                        eventRow($row)
                    }
                    if result.backfillsBlockOff || result.backfillsBlockOn {
                        blockTimeNote
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            actions
        }
        .background(Color.cockpitBackground.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Reconciliation.title)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)
            Text(L10n.Reconciliation.subtitle)
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Rows

    private func eventRow(_ row: Binding<FlightReconciliation.EventRow>) -> some View {
        let value = row.wrappedValue
        return HStack(spacing: 12) {
            Image(systemName: icon(for: value.type))
                .font(.system(size: 20))
                .foregroundColor(color(for: value.type))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                // Type picker: the ambiguity band gets its human resolution here.
                Menu {
                    ForEach([FlightEventType.touchAndGo, .fullStop, .goAround], id: \.self) { type in
                        Button {
                            row.wrappedValue.type = type
                        } label: {
                            Label(type.rawValue, systemImage: icon(for: type))
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(value.type.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primaryText)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.dimText)
                    }
                }
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: value.timestamp))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondaryText)
                    if let ident = value.airportIdent {
                        Text(ident)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.dimText)
                    }
                    badge(for: value.source)
                }
            }

            Spacer()

            if case .detectedOnly = value.source {
                // Detected rows can be excluded — the pilot's word beats the track's.
                Button {
                    row.wrappedValue.included.toggle()
                } label: {
                    Image(systemName: value.included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundColor(value.included ? .aviationGreen : .dimText)
                }
                .accessibilityLabel(value.included
                                    ? L10n.Reconciliation.includedLabel
                                    : L10n.Reconciliation.excludedLabel)
            }
        }
        .padding(14)
        .opacity(value.included ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor(for: value.source), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func badge(for source: FlightReconciliation.EventRow.Source) -> some View {
        switch source {
        case .confirmed:
            badgeLabel(L10n.Reconciliation.badgeConfirmed, color: .aviationGreen)
        case .detectedOnly:
            badgeLabel(L10n.Reconciliation.badgeDetected, color: .aviationAmber)
        case .typeMismatch(let recorded):
            badgeLabel(L10n.Reconciliation.badgeWas(recorded.rawValue), color: .orange)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
    }

    private var blockTimeNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15))
                .foregroundColor(.aviationGreen)
            Text(L10n.Reconciliation.blockBackfill)
                .font(.system(size: 12))
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground.opacity(0.6)))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                var applied = result
                applied.events = rows
                onApply(applied)
            } label: {
                Text(L10n.Reconciliation.apply)
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
            }
            Button(action: onKeep) {
                Text(L10n.Reconciliation.keepRecorded)
                    .font(.headline)
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private func icon(for type: FlightEventType) -> String {
        switch type {
        case .goAround: return "arrow.up.right.circle.fill"
        case .touchAndGo: return "arrow.down.forward.and.arrow.up.backward.circle.fill"
        case .fullStop: return "stop.circle.fill"
        }
    }

    private func color(for type: FlightEventType) -> Color {
        switch type {
        case .goAround: return .orange
        case .touchAndGo: return .blue
        case .fullStop: return .aviationAmber
        }
    }

    private func borderColor(for source: FlightReconciliation.EventRow.Source) -> Color {
        switch source {
        case .confirmed: return Color.white.opacity(0.10)
        case .detectedOnly: return Color.aviationAmber.opacity(0.5)
        case .typeMismatch: return Color.orange.opacity(0.5)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}
