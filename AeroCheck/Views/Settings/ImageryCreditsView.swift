import SwiftUI

/// About › Data sources › Aerial imagery: every imagery source the pilot's map may show, its credit in the provider's
/// own words, its licence linked, and the change note where the licence asks for one (we clip each source at its
/// border). The licence register's rules 1 to 3. (6.8.0)
struct ImageryCreditsView: View {
    @Environment(\.openURL) private var openURL
    private let tint: Color = .aviationGold
    private let sources = PilotMap.imagery.sources.map(\.source)

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L10n.PilotMap.imageryTitle, tint: tint, footer: L10n.PilotMap.imageryFooter) {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        link(source.creditLine(), source.creditLink)
                            .font(.aero(.subheadline))
                        HStack(spacing: 6) {
                            link(source.licence, source.licenceLink)
                            if source.changeNote {
                                Text("·").accessibilityHidden(true)
                                Text(L10n.PilotMap.clippedAtBorder)
                            }
                        }
                        .font(.aero(.caption))
                        .foregroundColor(.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .navigationTitle(L10n.PilotMap.imageryTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func link(_ text: String, _ address: String?) -> some View {
        if let address, let url = URL(string: address) {
            Button(text) { openURL(url) }
                .buttonStyle(.plain)
                .foregroundColor(tint)
                .multilineTextAlignment(.leading)
        } else {
            Text(text)
        }
    }
}
