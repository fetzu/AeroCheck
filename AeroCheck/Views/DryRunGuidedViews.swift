import SwiftUI

// MARK: - Dry run (6.4.0): where the guided flight is offered

/// Today's offer of the guided flight, while the logbook is empty: until the pilot has flown it (or a real
/// flight), or said Not now, which hides it for good on this device (D7); Settings keeps the offer.
struct DryRunTodayCard: View {
    let isCompact: Bool
    @Environment(AppState.self) private var appState
    @AppStorage(DryRunCenter.todayCardDismissedKey) private var dismissed = false
    @AppStorage(DryRunCenter.guidedFlownKey) private var guidedFlown = false

    /// Shown: nothing in the logbook, the guided flight never flown here, the card never put away.
    static func isOffered(logbookEmpty: Bool, dismissed: Bool, guidedFlown: Bool) -> Bool {
        logbookEmpty && !dismissed && !guidedFlown
    }

    var body: some View {
        if Self.isOffered(logbookEmpty: appState.flights.isEmpty, dismissed: dismissed, guidedFlown: guidedFlown),
           !appState.isFlightActive {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "airplane.circle")
                        .font(.aero(size: 22, weight: .semibold))
                        .foregroundColor(.aviationGold)
                        .accessibilityHidden(true)
                    Text(L10n.DryRunCoach.todayTitle)
                        .font(.aero(size: isCompact ? 17 : 19, weight: .bold))
                        .foregroundColor(.primaryText)
                }
                Text(L10n.DryRunCoach.todayBody)
                    .font(.aero(size: isCompact ? 14 : 15))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { DryRunCenter.shared.requestGuided() } label: {
                        Text(L10n.DryRunCoach.todayStart)
                            .font(.aero(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationGold))
                    }
                    .buttonStyle(.plain)
                    Button { dismissed = true } label: {
                        Text(L10n.DryRunCoach.todayNotNow)
                            .font(.aero(size: 15, weight: .semibold))
                            .foregroundColor(.aviationGold)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.aviationGold, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.aviationGold.opacity(0.4), lineWidth: 1))
        }
    }
}

/// Settings › About › The chapters one by one: each chapter of the guided flight on its own, the aircraft
/// placed where it starts.
struct DryRunChaptersView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPage {
            SettingsGroup(tint: .aviationGold, footer: L10n.DryRunCoach.chaptersFooter) {
                ForEach(1...DryRunChapters.count, id: \.self) { chapter in
                    SettingsButtonRow(icon: "\(chapter).circle", title: DryRunChapters.title(chapter),
                                      subtitle: DryRunChapters.habit(chapter), tint: .aviationGold, showsChevron: false) {
                        DryRunCenter.shared.requestGuided(chapter: chapter)
                    }
                    .disabled(appState.isFlightActive)
                }
            }
        }
        .navigationTitle(L10n.DryRunCoach.chaptersRow)
        .navigationBarTitleDisplayMode(.inline)
    }
}
