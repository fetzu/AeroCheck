import SwiftUI

/// First-run onboarding (v4.1.0 revamp). Seven steps: welcome → location priming → maps & data
/// downloads → checklists → your map → in flight & features → ready. The three middle "config" steps
/// fold a one-line intro into a header and let the pilot tune the default-off/on features up front; the
/// toggles bind straight to `AppSettings` and persist when onboarding completes. Cockpit language:
/// tinted page icons, gold primary actions, custom gold page dots. (onboarding revamp)
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @State private var currentPage = 0

    private let totalPages = 7

    /// Home country (ISO-2) from the device region — the default for the data-download suggestions.
    /// GPS refinement + neighbouring countries land in a follow-up increment. (onboarding revamp)
    private var homeCountry: String { Locale.current.region?.identifier ?? "US" }

    private let toggleColumns = [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]

    var body: some View {
        ZStack {
            Color.cockpitBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
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

                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    locationPage.tag(1)
                    mapsDataPage.tag(2)
                    checklistsPage.tag(3)
                    yourMapPage.tag(4)
                    inFlightFeaturesPage.tag(5)
                    readyPage.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 1: Welcome

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

    // MARK: - 2: Location priming

    private var locationPage: some View {
        VStack(spacing: 20) {
            Spacer()

            pageIcon("location.fill", tint: .aviationGreen, iconSize: 46)
            pageTitle(String(localized: "Use your location"))

            VStack(alignment: .leading, spacing: 11) {
                locationBullet("location.fill", String(localized: "Record your GPS flight track"))
                locationBullet("antenna.radiowaves.left.and.right", String(localized: "Show nearby airspace & frequencies"))
                locationBullet("square.and.arrow.down", String(localized: "Suggest the right maps to download next"))
            }
            .padding(.horizontal, 50)

            Spacer()

            pageDots
            VStack(spacing: 10) {
                primaryButton(String(localized: "Enable location"), icon: "location.fill") {
                    locationManager.requestAuthorization()
                    withAnimation { currentPage = 2 }
                }
                Button(String(localized: "Not now")) { withAnimation { currentPage = 2 } }
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .padding(.vertical, 4)
            }
            .padding(.bottom, 40)
        }
    }

    // MARK: - 3: Maps & data

    private var mapsDataPage: some View {
        configContainer(
            icon: "map.fill", tint: .aviationGreen,
            title: String(localized: "Maps & data"),
            subtitle: String(localized: "Download what you'll fly over — offline-ready."),
            page: 2
        ) {
            VStack(spacing: 12) {
                downloadButton(
                    title: String(localized: "Airspace, navaids & reporting points"),
                    icon: "shield.lefthalf.filled",
                    isDownloading: openAIPDataService.isDownloading,
                    progress: openAIPDataService.downloadProgress,
                    isCompleted: openAIPDataService.isDataAvailable,
                    action: { Task { await openAIPDataService.downloadData(for: [homeCountry]) } }
                )
                downloadButton(
                    title: String(localized: "Airports & frequencies"),
                    icon: "building.2",
                    isDownloading: airportDataService.isDownloading,
                    progress: airportDataService.downloadProgress,
                    isCompleted: airportDataService.isDataAvailable,
                    action: { Task { await airportDataService.downloadData() } }
                )
                downloadButton(
                    title: String(localized: "Swiss charts"),
                    icon: "map",
                    isDownloading: offlineMapManager.isDownloading,
                    progress: offlineMapManager.downloadProgress,
                    isCompleted: offlineMapManager.isCacheAvailable,
                    action: { Task { await offlineMapManager.downloadCharts(option: .icaoAndSegelflug) } }
                )
                Text(String(localized: "Add more countries anytime in Settings → Data."))
                    .font(.caption2)
                    .foregroundColor(.dimText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - 4: Checklists

    private var checklistsPage: some View {
        configContainer(
            icon: "checklist", tint: .altimeterBlue,
            title: String(localized: "Checklists"),
            subtitle: String(localized: "Interactive checklists for all 16 flight phases — set how you run them."),
            page: 3
        ) {
            VStack(spacing: 11) {
                LazyVGrid(columns: toggleColumns, spacing: 11) {
                    toggleRow("graduationcap", .altimeterBlue,
                              String(localized: "Learning mode"),
                              String(localized: "Show memorised items while you learn"),
                              $appState.settings.learningMode)
                    toggleRow("arrow.triangle.2.circlepath", .altimeterBlue,
                              String(localized: "Circuit mode"),
                              String(localized: "Streamlined pattern-training flow"),
                              $appState.settings.enableCircuitMode)
                }
                languageRow
            }
        }
    }

    // MARK: - 5: Your map

    private var yourMapPage: some View {
        configContainer(
            icon: "map.fill", tint: .aviationGreen,
            title: String(localized: "Your map"),
            subtitle: String(localized: "Swiss & worldwide layers on the moving map — pick what's drawn."),
            page: 4
        ) {
            LazyVGrid(columns: toggleColumns, spacing: 11) {
                toggleRow("shield.lefthalf.filled", .aviationGreen,
                          String(localized: "Airspace overlay"),
                          String(localized: "CTRs & zones from OpenAIP"),
                          $appState.settings.showOpenAIPOverlay)
                toggleRow("location.north.line", .aviationGreen,
                          String(localized: "Track vector"),
                          String(localized: "Trend line ahead of the aircraft"),
                          $appState.settings.showTrackVector)
                toggleRow("exclamationmark.triangle", .aviationGreen,
                          String(localized: "Obstacles"),
                          String(localized: "Masts, towers & wires"),
                          $appState.settings.showObstaclesOnMap)
                toggleRow("map", .aviationGreen,
                          String(localized: "Force ICAO chart"),
                          String(localized: "Keep the chart at all zoom levels"),
                          $appState.settings.forceICAOChartLayer)
            }
        }
    }

    // MARK: - 6: In flight & features

    private var inFlightFeaturesPage: some View {
        configContainer(
            icon: "airplane", tint: .aviationGold,
            title: String(localized: "In flight & features"),
            subtitle: String(localized: "How the app behaves in the air, plus the bigger features and your data."),
            page: 5
        ) {
            LazyVGrid(columns: toggleColumns, spacing: 11) {
                toggleRow("point.3.connected.trianglepath.dotted", .aviationGreen,
                          String(localized: "Flight planning"),
                          String(localized: "Map-first route builder"),
                          $appState.settings.enableFlightPlanning)
                toggleRow("wind", .altimeterBlue,
                          String(localized: "Estimated airspeed"),
                          String(localized: "MeteoSwiss wind estimate — beta (Switzerland)"),
                          $appState.settings.showEstimatedAirspeed)
                toggleRow("gauge.with.needle", .aviationGold,
                          String(localized: "Log engine hours"),
                          String(localized: "Prompt for the hour meter"),
                          $appState.settings.logEngineHours)
                toggleRow("icloud", .altimeterBlue,
                          String(localized: "Sync to iCloud"),
                          String(localized: "Flights & settings across devices"),
                          $appState.settings.iCloudSyncEnabled)
            }
        }
    }

    // MARK: - 7: Ready

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

    // MARK: - Config page scaffold

    /// A "config" step: a left-aligned header (icon + folded-in intro) over its content, with the page
    /// dots + a gold Continue button pinned to the foot. Used by the three setup steps + Maps & data.
    private func configContainer<Content: View>(
        icon: String, tint: Color, title: String, subtitle: String, page: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(tint)
                    .frame(width: 50, height: 50)
                    .background(RoundedRectangle(cornerRadius: 15).fill(tint.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.primaryText)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.bottom, 18)

            content()

            Spacer(minLength: 16)

            HStack {
                pageDots
                Spacer()
                inlinePrimary(String(localized: "Continue"), icon: "arrow.right") {
                    withAnimation { currentPage = page + 1 }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 40)
    }

    // MARK: - Reusable components

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

    private func locationBullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundColor(.aviationGreen)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundColor(.primaryText)
            Spacer(minLength: 0)
        }
    }

    /// A feature toggle card (icon + title + subtitle + switch) bound straight to an `AppSettings` flag.
    private func toggleRow(_ icon: String, _ iconTint: Color, _ title: String, _ subtitle: String,
                           _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundColor(iconTint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primaryText)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.aviationGold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }

    /// Full-width checklist-language row with a compact Auto / EN / FR segmented control.
    private var languageRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "globe")
                .font(.system(size: 19))
                .foregroundColor(.altimeterBlue)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Checklist language"))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primaryText)
                Text(String(localized: "Auto follows your device language"))
                    .font(.caption2)
                    .foregroundColor(.dimText)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(ChecklistLanguage.availableLanguages) { lang in
                    Button { appState.settings.checklistLanguage = lang } label: {
                        Text(langShort(lang))
                            .font(.caption.weight(.medium))
                            .foregroundColor(appState.settings.checklistLanguage == lang ? .black : .secondaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(appState.settings.checklistLanguage == lang ? Color.aviationGold : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.cockpitBackground)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func langShort(_ lang: ChecklistLanguage) -> String {
        switch lang {
        case .auto: return String(localized: "Auto")
        default: return lang.rawValue.uppercased()
        }
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

    /// Compact gold button for the config steps' footer.
    private func inlinePrimary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.body.weight(.semibold))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(.black)
            .padding(.vertical, 11)
            .padding(.horizontal, 24)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
        }
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
