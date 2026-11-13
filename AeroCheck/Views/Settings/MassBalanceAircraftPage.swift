import SwiftUI

/// Settings › Aircraft › the registration's mass and balance (6.11.0, the author's m11): the figures
/// the sheet works with for this aircraft, where they come from and at which revision, the pilot's
/// confirmation, and the empty mass. The sheet itself opens from here as a check of the aircraft
/// alone, without a flight.
struct MassBalanceAircraftPage: View {
    let registration: String

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var aircraftDataService: AircraftDataService
    @State private var showSteps = false
    @State private var showSheet = false
    @State private var showOwn = false

    private let tint: Color = .aviationGold

    private var shipped: AircraftMassBalance? {
        _ = aircraftDataService.massBalanceChangeCount
        return aircraftDataService.massBalance(forRegistration: registration)
    }

    var body: some View {
        let setup = appState.settings.massBalance[registration]
        let basis = setup.basis(shipped: shipped, now: Date())
        SettingsPage {
            if let basis {
                SettingsGroup(title: L10n.MassBalance.settingsFigures, tint: tint) {
                    ForEach(Array(MassBalanceFacts.identityRows(for: basis.data).enumerated()), id: \.offset) { _, row in
                        MassBalanceSettingsFact(label: row.0, value: row.1)
                    }
                }
                SettingsGroup(title: L10n.MassBalance.settingsSource, tint: tint) {
                    if basis.source == .pilot {
                        MassBalanceSettingsLine(text: L10n.MassBalance.footYours)
                        SettingsButtonRow(icon: "pencil", title: L10n.MassBalance.ownChange, tint: tint) { showOwn = true }
                    } else {
                        ForEach(Array((basis.data.sources ?? []).enumerated()), id: \.offset) { _, source in
                            MassBalanceSettingsLine(text: [source.document, source.revision.map { "rev. \($0)" },
                                                           source.date.map(MassBalanceWords.day)]
                                .compactMap { $0 }.joined(separator: " · "))
                        }
                        MassBalanceSettingsLine(text: L10n.MassBalance.settingsRevision(basis.data.revision,
                                                                                        MassBalanceWords.day(basis.data.updated)))
                    }
                }
                SettingsGroup(title: L10n.MassBalance.settingsConfirmation, tint: tint, footer: L10n.MassBalance.step3Again) {
                    MassBalanceSettingsLine(text: Self.confirmation(basis, setup: setup, registration: registration),
                                            colour: basis.isConfirmed ? .aviationGreen : .aviationAmber,
                                            symbol: basis.isConfirmed ? "checkmark" : "questionmark")
                    if basis.source == .shipped, shipped != nil {
                        SettingsButtonRow(icon: "doc.text.magnifyingglass", title: L10n.MassBalance.buttonCheckData,
                                          subtitle: L10n.MassBalance.step1Title, tint: tint) { showSteps = true }
                    }
                }
                if let empty = basis.empty {
                    SettingsGroup(title: L10n.MassBalance.step2Title, tint: tint,
                                  footer: basis.emptyIsPilots ? L10n.MassBalance.settingsYourLine : nil) {
                        MassBalanceSettingsFact(label: L10n.MassBalance.step2Date, value: MassBalanceWords.day(empty.date))
                        MassBalanceSettingsFact(label: L10n.MassBalance.step2Mass, value: MassBalanceWords.mass(empty.mass, basis.data.units))
                        MassBalanceSettingsFact(label: L10n.MassBalance.tableMoment,
                                                value: "\(MassBalanceWords.momentFigure(empty.moment, basis.data.units)) \(basis.data.units.mass.rawValue)·\(basis.data.units.arm.rawValue)")
                        MassBalanceSettingsFact(label: L10n.MassBalance.step2Cg,
                                                value: empty.arm.map { MassBalanceWords.arm($0, basis.data.units) } ?? "—")
                    }
                }
            } else {
                // No data from the server, or data the pilot said isn't this aircraft's.
                SettingsGroup(title: L10n.MassBalance.settingsFigures, tint: tint) {
                    MassBalanceSettingsLine(text: shipped == nil ? L10n.MassBalance.nodataBody(registration)
                                                                 : L10n.MassBalance.nodataDeclined(registration))
                    SettingsButtonRow(icon: "pencil", title: L10n.MassBalance.ownEnter, subtitle: L10n.MassBalance.ownWhy,
                                      tint: tint) { showOwn = true }
                    if shipped != nil {
                        SettingsButtonRow(icon: "doc.text.magnifyingglass", title: L10n.MassBalance.nodataLookAgain,
                                          subtitle: L10n.MassBalance.step1Title, tint: tint) { showSteps = true }
                    }
                }
            }
            SettingsGroup(footer: L10n.MassBalance.footDecides) {
                SettingsButtonRow(icon: "scalemass", title: L10n.MassBalance.settingsOpen,
                                  subtitle: L10n.MassBalance.settingsOpenNote, tint: tint) { showSheet = true }
            }
        }
        .navigationTitle("\(registration) · \(L10n.MassBalance.title)")
        .navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showSheet) {
            MassBalanceEntryView(registration: registration, onClose: { showSheet = false })
                .environmentObject(aircraftDataService)
        }
        .task { await aircraftDataService.refreshMassBalance(forRegistration: registration) }
    }

    /// Where the confirmation stands, in one line: also the row's subtitle on the Aircraft page.
    static func confirmation(_ basis: MassBalanceBasis, setup: MassBalanceSetup, registration: String) -> String {
        if basis.isConfirmed {
            let at = basis.source == .shipped ? setup.confirmedAt : setup.ownConfirmedAt
            return at.map { L10n.MassBalance.settingsConfirmedOn($0.formatted(date: .abbreviated, time: .omitted)) }
                ?? L10n.MassBalance.settingsNotConfirmed
        }
        switch basis.unconfirmed {
        case .dataChanged: return L10n.MassBalance.lineDataChanged(registration)
        case .yearPassed: return L10n.MassBalance.lineYearPassed(registration)
        default: return L10n.MassBalance.settingsNotConfirmed
        }
    }

    /// The Aircraft page's row for a registration: what its sheet works with.
    static func summary(registration: String, shipped: AircraftMassBalance?, setup: MassBalanceSetup, now: Date = Date()) -> String {
        guard let basis = setup.basis(shipped: shipped, now: now) else {
            return shipped == nil ? L10n.MassBalance.settingsOwnFigures : L10n.MassBalance.settingsSwitchedOff
        }
        return confirmation(basis, setup: setup, registration: registration)
    }
}

/// A label and its figure, in a settings group.
private struct MassBalanceSettingsFact: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.aero(.subheadline))
                .foregroundColor(.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.aero(.subheadline, design: .monospaced))
                .foregroundColor(.primaryText)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// A line of words in a settings group, with its shape when it is a state.
private struct MassBalanceSettingsLine: View {
    let text: String
    var colour: Color = .primaryText
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.aero(size: 14, weight: .bold))
                    .foregroundColor(colour)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.aero(.subheadline))
                .foregroundColor(colour)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
