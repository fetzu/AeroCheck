import SwiftUI

/// The safety notice, shown as a blocking gate on first run and reviewable from Settings.
///
/// Deliberately placed BEFORE `OnboardingView` in `ContentView` rather than as a page inside it:
/// onboarding carries a "Skip" button that jumps straight to `completeOnboarding()`, so a
/// disclaimer page living inside the TabView would be skippable in one tap — which is the one
/// thing an acknowledgement must not be. Every comparable app (ForeFlight, Garmin Pilot,
/// SkyDemon) gates the same way.
///
/// The four points are the ones the peers converge on, plus the one that is specific to us: our
/// checklists are transcriptions of club documents, not approved checklists, and the AFM/POH wins
/// every disagreement. The full text lives at aerocheck.app/terms.
struct DisclaimerView: View {
    /// `gate` blocks first launch until accepted; `review` is the same text, dismissible, opened
    /// from Settings → About → Legal.
    enum Mode { case gate, review }

    let mode: Mode
    var onAccept: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(mode: Mode = .gate, onAccept: (() -> Void)? = nil) {
        self.mode = mode
        self.onAccept = onAccept
    }

    var body: some View {
        ZStack {
            Color.cockpitBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // GeometryReader + minHeight so the notice sits centred on an iPad, where it fits
                // with room to spare, and scrolls normally on a phone or at large Dynamic Type.
                // Without it the text hugs the top and leaves a third of the iPad blank.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 22) {
                            header
                            points
                            termsLink
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                footer
            }
        }
        .preferredColorScheme(.dark)
        // A gate must not be dismissible by a swipe or a back-swipe either; `.interactiveDismissDisabled`
        // is harmless in `.gate` (not presented as a sheet) and correct in `.review` only when accepting.
        .interactiveDismissDisabled(mode == .gate)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundColor(.aviationAmber)
                .accessibilityHidden(true)

            Text(L10n.Disclaimer.title)
                .font(.title2.weight(.bold))
                .foregroundColor(.primaryText)
                .multilineTextAlignment(.center)

            Text(L10n.Disclaimer.intro)
                .font(.callout)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Points

    private var points: some View {
        VStack(alignment: .leading, spacing: 14) {
            point("questionmark.app.dashed",
                  L10n.Disclaimer.notCertifiedTitle, L10n.Disclaimer.notCertifiedBody)
            point("book.closed",
                  L10n.Disclaimer.checklistTitle, L10n.Disclaimer.checklistBody)
            point("dot.radiowaves.left.and.right",
                  L10n.Disclaimer.dataTitle, L10n.Disclaimer.dataBody)
            point("person.crop.circle.badge.exclamationmark",
                  L10n.Disclaimer.pilotTitle, L10n.Disclaimer.pilotBody)
        }
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.aviationAmber)
                .frame(width: 26, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primaryText)
                Text(body)
                    .font(.footnote)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.subtleOverlay(0.07), lineWidth: 1)
        )
        // One point = one accessibility element; the icon is decorative and already hidden.
        .accessibilityElement(children: .combine)
    }

    // MARK: - Terms link

    private var termsLink: some View {
        Button {
            openURL(DisclaimerView.termsURL)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text(L10n.Disclaimer.readTerms)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .foregroundColor(.aviationGold)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            Text(L10n.Disclaimer.asIs)
                .font(.caption2)
                .foregroundColor(.dimText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: primaryAction) {
                Text(mode == .gate ? L10n.Disclaimer.accept : L10n.Button.close)
                    .font(.headline)
                    .foregroundColor(.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.aviationGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(
            Color.cockpitBackground
                .overlay(Rectangle().fill(Color.subtleOverlay(0.08)).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func primaryAction() {
        switch mode {
        case .gate: onAccept?()
        case .review: dismiss()
        }
    }

    /// Canonical location of the full text. Kept here (not inlined at three call sites) so the app
    /// cannot end up pointing at two different URLs — the paywall shipped a dead `/terms` link once
    /// already, see SubscriptionView.
    static let termsURL = URL(string: "https://aerocheck.app/terms")!
}

#Preview("Gate") {
    DisclaimerView(mode: .gate, onAccept: {})
}

#Preview("Review") {
    DisclaimerView(mode: .review)
}
