import SwiftUI

/// Onboarding flow shown to new users on first launch
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
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 8)

                // Page content
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    checklistsPage.tag(1)
                    navigationPage.tag(2)
                    briefingsPage.tag(3)
                    readyPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("AppIconImage")
                .resizable()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .aviationGold.opacity(0.3), radius: 12)
                .overlay(
                    // Fallback if AppIconImage doesn't exist
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.aviationGold.opacity(0.3), lineWidth: 1)
                )

            Text(L10n.Onboarding.welcomeTitle)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primaryText)

            Text(L10n.Onboarding.welcomeSubtitle)
                .font(.system(size: 17))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { withAnimation { currentPage = 1 } }) {
                Text(L10n.Onboarding.getStarted)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.aviationGold)
                    )
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Page 2: Checklists

    private var checklistsPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 60))
                .foregroundColor(.aviationGold)

            Text(L10n.Onboarding.checklistsTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primaryText)

            Text(L10n.Onboarding.checklistsBody)
                .font(.system(size: 16))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            nextButton(page: 2)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Page 3: Navigation & Downloads

    private var navigationPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundColor(.aviationGold)

            Text(L10n.Onboarding.navigationTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primaryText)

            Text(L10n.Onboarding.navigationBody)
                .font(.system(size: 16))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)

            // Download buttons
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

            nextButton(page: 3)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Page 4: Briefings & Flight Log

    private var briefingsPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.aviationGold)

            Text(L10n.Onboarding.briefingsTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primaryText)

            Text(L10n.Onboarding.briefingsBody)
                .font(.system(size: 16))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            nextButton(page: 4)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Page 5: Ready to Fly

    private var readyPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "airplane.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.aviationGold)

            Text(L10n.Onboarding.readyTitle)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primaryText)

            Text(L10n.Onboarding.readyBody)
                .font(.system(size: 17))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: completeOnboarding) {
                Text(L10n.Onboarding.readyButton)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.aviationGold)
                    )
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Reusable Components

    private func nextButton(page: Int) -> some View {
        Button(action: { withAnimation { currentPage = page } }) {
            Text(L10n.Onboarding.next)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.aviationGold)
                )
        }
        .padding(.horizontal, 40)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primaryText)

                    if isDownloading {
                        ProgressView(value: progress)
                            .tint(.aviationGold)
                    } else if isCompleted {
                        Text(L10n.Onboarding.downloaded)
                            .font(.system(size: 12))
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.panelBackground)
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
        appState.settings.hasCompletedOnboarding = true
        appState.saveSettings()
    }
}
