import SwiftUI

/// The mass and balance sheet of a flight that has started: as it was, to read. (6.11.0, the author's m13)
///
/// Nothing here can be changed, and nothing is worked out again: the verdict, its words and the points
/// are the ones kept at the start of the flight. The record keeps what is shown here and not the
/// aircraft's file (the author's d2), so the load is listed as entered, without the handbook's arms.
struct MassBalanceRecordView: View {
    let record: FlightMassBalance
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isWide: Bool { sizeClass == .regular }

    private var result: MassBalanceResult { record.keptResult }
    private var data: AircraftMassBalance { record.drawnData }

    private var basis: MassBalanceBasis {
        // Its empty mass stands for "there was one": the words only ask whether it exists.
        MassBalanceBasis(data: data, source: record.isPilots ? .pilot : .shipped,
                         empty: record.emptyDate.map { .init(mass: 1, moment: 0, date: $0, entry: nil) },
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
                                MassBalanceChart(data: data, result: result)
                                    .frame(height: 380)
                                MassBalancePointCards(data: data, result: result, stacked: true)
                                    .frame(width: 230)
                            }
                        } else {
                            MassBalanceChart(data: data, result: result, compact: true)
                                .frame(height: 220)
                            MassBalancePointCards(data: data, result: result, stacked: false)
                        }
                        MassBalanceSectionTitle(text: L10n.MassBalance.loadTitle, note: nil)
                        MassBalanceKeptLoad(data: data, load: record.load)
                        VStack(spacing: 6) {
                            Text(figures + " " + L10n.MassBalance.footDecides)
                                .scaledFont(size: 14, relativeTo: .footnote)
                                .foregroundColor(.aviationAmber)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            if let date = record.emptyDate {
                                Text(L10n.MassBalance.labelled(L10n.MassBalance.rowEmpty,
                                                               L10n.MassBalance.rowRecordOf(MassBalanceWords.day(date))))
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
                        : L10n.MassBalance.recordFigures(record.registration, record.revision)
    }
}

/// The load as the pilot entered it, row by row, in kilograms and litres: a seat's mass or "Empty",
/// each baggage area, the fuel at engine start and the trip.
private struct MassBalanceKeptLoad: View {
    let data: AircraftMassBalance
    let load: MassBalanceLoad

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        for station in data.stations {
            switch station.kind {
            case .seats:
                for seat in station.seats ?? [] {
                    let value: String
                    switch load.seats[seat.id] ?? .unset {
                    case .person(let kg): value = "\(MassBalanceWords.plain(kg, decimals: kg == kg.rounded() ? 0 : 1)) kg"
                    case .empty: value = L10n.MassBalance.buttonEmpty
                    case .unset: value = "—"
                    }
                    rows.append((MassBalanceWords.seatName(seat, in: data), value))
                }
            case .baggage:
                rows.append((MassBalanceWords.rowName(station, in: data),
                             load.baggageKg[station.id].map { "\(MassBalanceWords.plain($0, decimals: $0 == $0.rounded() ? 0 : 1)) kg" } ?? "—"))
            case .fuel:
                break
            }
        }
        rows.append(("\(L10n.MassBalance.rowFuel), \(L10n.MassBalance.rowFuelStart)",
                     load.fuelLitres.map { "\(MassBalanceWords.litres($0)) L" } ?? "—"))
        rows.append((L10n.MassBalance.rowTrip, load.tripLitres.map { "\(MassBalanceWords.litres($0)) L" } ?? "—"))
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .scaledFont(size: 17, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(row.1)
                        .scaledFont(size: 22, design: .monospaced, relativeTo: .title3)
                        .foregroundColor(.primaryText)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { Divider().overlay(Color.white.opacity(0.06)) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
        .accessibilityIdentifier("mb.record.load")
    }
}
