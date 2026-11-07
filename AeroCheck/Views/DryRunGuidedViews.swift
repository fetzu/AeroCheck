import SwiftUI

// MARK: - Dry run (6.4.0): the story, part by part

/// Settings › About › One part at a time: each part of the story on its own, the flight it needs flown to it;
/// Fly's chapters on a page of their own. (6.4.0)
struct DryRunPartsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPage {
            SettingsGroup(tint: .aviationGold, footer: L10n.DryRunCoach.partsFooter) {
                ForEach(DryRunPart.allCases) { part in
                    SettingsButtonRow(icon: "\(part.rawValue).circle", title: part.title,
                                      subtitle: part.habit ?? DryRunChapters.habit(4), tint: .aviationGold,
                                      showsChevron: false) {
                        DryRunCenter.shared.requestGuided(DryRunStart(part: part))
                    }
                    .disabled(appState.isFlightActive)
                    if part == .fly {
                        NavigationLink {
                            DryRunChaptersView()
                        } label: {
                            HStack(spacing: 8) {
                                SettingsRowLabel(icon: "list.number", title: L10n.DryRunCoach.flyChapters,
                                                 tint: .aviationGold)
                                Image(systemName: "chevron.right")
                                    .font(.aero(size: 14, weight: .semibold))
                                    .foregroundColor(.dimText)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isFlightActive)
                    }
                }
            }
        }
        .navigationTitle(L10n.DryRunCoach.partsRow)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Fly it, chapter by chapter: each chapter of the flight on its own, the flight taken to where it starts.
struct DryRunChaptersView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPage {
            SettingsGroup(tint: .aviationGold, footer: L10n.DryRunCoach.chaptersFooter) {
                ForEach(1...DryRunChapters.count, id: \.self) { chapter in
                    SettingsButtonRow(icon: "\(chapter).circle", title: DryRunChapters.title(chapter),
                                      subtitle: DryRunChapters.habit(chapter), tint: .aviationGold, showsChevron: false) {
                        DryRunCenter.shared.requestGuided(DryRunStart(part: .fly, chapter: chapter))
                    }
                    .disabled(appState.isFlightActive)
                }
            }
        }
        .navigationTitle(L10n.DryRunCoach.flyChapters)
        .navigationBarTitleDisplayMode(.inline)
    }
}
