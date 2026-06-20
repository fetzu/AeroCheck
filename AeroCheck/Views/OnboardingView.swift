import SwiftUI

/// Onboarding flow shown to new users on first launch. Cockpit language: a tinted rounded-square
/// page icon, semantic Dynamic-Type fonts, gold primary action, and custom gold page dots. (v4 UI/UX Revamp)
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @State private var currentPage = 0

    private let totalPages = 5

    var body: some View {
        ZStack {
            Color.cockpitBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    Button(action: completeOnboarding) {
                        Text(L10n.Onboarding.skip)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 8)

                // Page content (custom gold dots below, system index hidden)
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    checklistsPage.tag(1)
                    navigationPage.tag(2)
                    briefingsPage.tag(3)
                    readyPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 22) {
            Spacer()

            Image("AppIconImage")
                .resizable()
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(Color.aviationGold.opacity(0.3), lineWidth: 1)
                )
                .accessibilityHidden(true)

            Text(L10n.Onboarding.welcomeTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primaryText)
                .multilineTextAlignment(.center)

            Text(L10n.Onboarding.welcomeSubtitle)
                .font(.body)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            pageDots
            primaryButton(L10n.Onboarding.getStarted, icon: "arrow.right") { withAnimation { currentPage = 1 } }
                .padding(.bottom, 44)
        }
    }

    // MARK: - Page 2: Checklists

    private var checklistsPage: some View {
        VStack(spacing: 22) {
            Spacer()
            pageIcon("checklist", tint: .altimeterBlue)
            pageTitle(L10n.Onboarding.checklistsTitle)
            pageBody(L10n.Onboarding.checklistsBody)
            Spacer()
            pageDots
            nextButton(page: 2).padding(.bottom, 44)
        }
    }

    // MARK: - Page 3: Navigation & Downloads

    private var navigationPage: some View {
        VStack(spacing: 18) {
            Spacer()
            pageIcon("map", tint: .aviationGreen)
            pageTitle(L10n.Onboarding.navigationTitle)
            pageBody(L10n.Onboarding.navigationBody)

            VStack(spacing: 12) {
                downloadButton(
                    title: L10n.Onboarding.downloadAirports,
                    icon: "building.2",
                    isDownloading: airportDataService.isDownloading,
                    progress: airportDataService.downloadProgress,
                    isCompleted: airportDataService.isDataAvailable,
                    action: { Task { await airportDataService.downloadData() } }
                )
                downloadButton(
                    title: L10n.Onboarding.downloadCharts,
                    icon: "map.fill",
                    isDownloading: offlineMapManager.isDownloading,
                    progress: offlineMapManager.downloadProgress,
                    isCompleted: offlineMapManager.isCacheAvailable,
                    action: { Task { await offlineMapManager.downloadCharts(option: .icaoAndSegelflug) } }
                )
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)

            Spacer()
            pageDots
            nextButton(page: 3).padding(.bottom, 44)
        }
    }

    // MARK: - Page 4: Briefings & Flight Log

    private var briefingsPage: some View {
        VStack(spacing: 22) {
            Spacer()
            pageIcon("doc.text.magnifyingglass", tint: .aviationGold)
            pageTitle(L10n.Onboarding.briefingsTitle)
            pageBody(L10n.Onboarding.briefingsBody)
            Spacer()
            pageDots
            nextButton(page: 4).padding(.bottom, 44)
        }
    }

    // MARK: - Page 5: Ready to Fly

    private var readyPage: some View {
        VStack(spacing: 22) {
            Spacer()
            pageIcon("airplane.circle.fill", tint: .aviationGold, iconSize: 46)
            Text(L10n.Onboarding.readyTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primaryText)
                .multilineTextAlignment(.center)
            pageBody(L10n.Onboarding.readyBody)
            Spacer()
            pageDots
            primaryButton(L10n.Onboarding.readyButton, icon: "airplane") { completeOnboarding() }
                .padding(.bottom, 44)
        }
    }

    // MARK: - Reusable Components

    /// A tinted rounded-square page icon (cockpit language).
    private func pageIcon(_ name: String, tint: Color, iconSize: CGFloat = 40) -> some View {
        Image(systemName: name)
            .font(.system(size: iconSize))
            .foregroundColor(tint)
            .frame(width: 88, height: 88)
            .background(RoundedRectangle(cornerRadius: 24).fill(tint.opacity(0.14)))
            .accessibilityHidden(true)
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(.title.weight(.bold))
            .foregroundColor(.primaryText)
            .multilineTextAlignment(.center)
    }

    private func pageBody(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Custom gold page indicator (active dot elongates), replacing the system index dots.
    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<totalPages, id: \.self) { i in
                Capsule()
                    .fill(i == currentPage ? Color.aviationGold : Color.dimText.opacity(0.5))
                    .frame(width: i == currentPage ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: currentPage)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(currentPage + 1) of \(totalPages)")
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body.weight(.semibold))
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold))
        }
        .padding(.horizontal, 40)
    }

    private func nextButton(page: Int) -> some View {
        primaryButton(L10n.Onboarding.next, icon: "arrow.right") { withAnimation { currentPage = page } }
    }

    private func downloadButton(
        title: String,
        icon: String,
        isDownloading: Bool,
        progress: Double,
        isCompleted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            if !isDownloading && !isCompleted {
                action()
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 20))
                    .foregroundColor(isCompleted ? .aviationGreen : .aviationGold)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primaryText)

                    if isDownloading {
                        ProgressView(value: progress)
                            .tint(.aviationGold)
                    } else if isCompleted {
                        Text(L10n.Onboarding.downloaded)
                            .font(.caption)
                            .foregroundColor(.aviationGreen)
                    }
                }

                Spacer()

                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if !isCompleted {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.aviationGold)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isCompleted ? Color.aviationGreen.opacity(0.3) : Color.aviationGold.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .disabled(isDownloading || isCompleted)
    }

    // MARK: - Actions

    private func completeOnboarding() {
        appState.completeOnboarding()
    }
}
