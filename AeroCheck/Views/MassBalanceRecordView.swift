import SwiftUI

/// The mass and balance sheet of a flight that has started: as it was, to read. (6.11.0, the author's m13)
///
/// Nothing here can be changed, and nothing is worked out again for the verdict or the points: they
/// are the ones kept at the start of the flight, with the figures they were worked with.
struct MassBalanceRecordView: View {
    let record: FlightMassBalance
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isWide: Bool { sizeClass == .regular }

    /// For the margins' words and the table's rows; the verdict and the points stay the kept ones.
    private var result: MassBalanceResult {
        var result = MassBalanceCalculator.compute(data: record.data, empty: record.empty, load: record.load,
                                                   isConfirmed: record.isConfirmed)
        result.verdict = record.verdict
        result.takeoff = record.takeoff
        result.landing = record.landing
        result.emptyTanks = record.emptyTanks
        return result
    }

    private var basis: MassBalanceBasis {
        MassBalanceBasis(data: record.data, source: record.isPilots ? .pilot : .shipped, empty: record.empty,
                         emptyIsPilots: false, isConfirmed: record.isConfirmed,
                         unconfirmed: record.isConfirmed ? nil : .never)
    }

    /// The verdict's lines, without the one that tells the pilot what to do next: there is no next.
    private func lines(_ result: MassBalanceResult) -> [String] {
        MassBalanceWords.lines(for: result, basis: basis, registration: record.registration, load: record.load)
            .filter { $0 != L10n.MassBalance.lineLastTimeHow }
    }

    var body: some View {
        let result = self.result
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        Label(L10n.MassBalance.recordNote(record.keptAt.formatted(date: .abbreviated, time: .shortened)),
                              systemImage: "lock.fill")
                            .scaledFont(size: 15, relativeTo: .subheadline)
                            .foregroundColor(.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("mb.record.note")
                        MassBalanceVerdictCard(verdict: result.verdict, lines: lines(result), onTodays: {},
                                               onCheckData: nil, isReadOnly: true)
                        if isWide {
                            HStack(alignment: .top, spacing: 14) {
                                MassBalanceChart(data: record.data, result: result)
                                    .frame(height: 380)
                                MassBalancePointCards(data: record.data, result: result, stacked: true)
                                    .frame(width: 230)
                            }
                        } else {
                            MassBalanceChart(data: record.data, result: result, compact: true)
                                .frame(height: 220)
                            MassBalancePointCards(data: record.data, result: result, stacked: false)
                        }
                        MassBalanceSectionTitle(text: L10n.MassBalance.loadTitle, note: nil)
                        // The handbook's form on both widths: on a narrow screen it scrolls sideways
                        // rather than lose a column.
                        if isWide {
                            MassBalanceLoadTable(data: record.data, empty: record.empty, result: result, load: record.load)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                MassBalanceLoadTable(data: record.data, empty: record.empty, result: result, load: record.load)
                                    .frame(minWidth: 480)
                            }
                        }
                        VStack(spacing: 6) {
                            Text(figures + " " + L10n.MassBalance.footDecides)
                                .scaledFont(size: 14, relativeTo: .footnote)
                                .foregroundColor(.aviationAmber)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            if let empty = record.empty {
                                Text("\(L10n.MassBalance.rowEmpty): \(L10n.MassBalance.rowRecordOf(MassBalanceWords.day(empty.date)))")
                                    .scaledFont(size: 12, relativeTo: .caption)
                                    .foregroundColor(.dimText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                    }
                    .padding(isWide ? 20 : 14)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("\(record.registration) · \(L10n.MassBalance.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { if let onClose { onClose() } else { dismiss() } }
                }
            }
        }
        .pageSizedSheet()
    }

    private var figures: String {
        record.isPilots ? L10n.MassBalance.footYours
                        : L10n.MassBalance.recordFigures(record.registration, record.data.revision)
    }
}
