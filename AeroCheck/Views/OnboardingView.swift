import SwiftUI
import CoreLocation

/// Curated land-border adjacency for the onboarding "download my region" suggestions. Major bordering
/// countries only — micro-states (LI/MC/SM/AD/VA) are omitted to keep the suggestion list tidy. ISO-2,
/// uppercase. Not exhaustive: a country absent from the table simply gets no neighbour suggestions.
enum CountryNeighbors {
    static func neighbors(of country: String) -> [String] {
        table[country.uppercased()] ?? []
    }

    static let table: [String: [String]] = [
        "CH": ["FR", "DE", "IT", "AT"],
        "FR": ["BE", "LU", "DE", "CH", "IT", "ES"],
        "DE": ["DK", "PL", "CZ", "AT", "CH", "FR", "LU", "BE", "NL"],
        "IT": ["FR", "CH", "AT", "SI"],
        "AT": ["DE", "CZ", "SK", "HU", "SI", "IT", "CH"],
        "BE": ["FR", "LU", "DE", "NL"],
        "NL": ["BE", "DE"],
        "LU": ["BE", "FR", "DE"],
        "ES": ["PT", "FR"],
        "PT": ["ES"],
        "GB": ["IE"],
        "IE": ["GB"],
        "DK": ["DE"],
        "PL": ["DE", "CZ", "SK", "LT"],
        "CZ": ["DE", "PL", "SK", "AT"],
        "SK": ["CZ", "PL", "HU", "AT"],
        "HU": ["SK", "RO", "RS", "HR", "SI", "AT"],
        "SI": ["AT", "IT", "HU", "HR"],
        "HR": ["SI", "HU", "RS", "BA"],
        "NO": ["SE", "FI"],
        "SE": ["NO", "FI"],
        "FI": ["SE", "NO"],
        "RO": ["HU", "BG", "RS"],
        "BG": ["RO", "RS", "GR"],
        "GR": ["BG"],
        "US": ["CA", "MX"],
        "CA": ["US"],
        "MX": ["US"],
    ]
}

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
    // The other OpenAIP layers download alongside airspace; observed so the card reflects all of them.
    @ObservedObject private var navaidService = OpenAIPNavaidDataService.shared
    @ObservedObject private var obstacleService = OpenAIPObstacleDataService.shared
    @ObservedObject private var reportingPointService = OpenAIPReportingPointDataService.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var currentPage = 0
    @State private var showSkipConfirm = false
    @State private var showNoDownloadWarning = false

    /// GPS-reverse-geocoded home country (ISO-2); nil until/unless a fix resolves. (onboarding revamp)
    @State private var detectedCountry: String?
    /// Countries selected for the OpenAIP download — seeded with the home country, neighbours opt-in.
    @State private var selectedCountries: Set<String> = []

    private let totalPages = 7

    /// Effective home country: the GPS-detected one if available, else the device region. (onboarding revamp)
    private var effectiveHome: String { detectedCountry ?? (Locale.current.region?.identifier ?? "US") }

    /// One full-width column on iPhone (compact), two on iPad — a 2-up grid is unreadable at phone width.
    private var toggleColumns: [GridItem] {
        horizontalSizeClass == .compact
            ? [GridItem(.flexible(), spacing: 11)]
            : [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)]
    }

    /// True when every selected country's airspace is already cached — drives the "Downloaded" state so
    /// it reflects the CURRENT selection (selecting a new country flips it back to needing a download).
    private var openAIPFullyDownloaded: Bool {
        let downloaded = Set(openAIPDataService.downloadedCountries.map { $0.uppercased() })
        var wanted = selectedCountries
        wanted.insert(effectiveHome)
        return !wanted.isEmpty && wanted.isSubset(of: downloaded)
    }

    var body: some View {
        ZStack {
            Color.cockpitBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: { showSkipConfirm = true }) {
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
        .confirmationDialog(String(localized: "Skip setup?"),
                            isPresented: $showSkipConfirm, titleVisibility: .visible) {
            Button(String(localized: "Skip anyway"), role: .destructive) { completeOnboarding() }
            Button(String(localized: "Keep setting up"), role: .cancel) {}
        } message: {
            Text(String(localized: "Without downloading airspace data you won't see airspace or frequencies while navigating. You can set this up later in Settings → Data."))
        }
        .confirmationDialog(String(localized: "No airspace data downloaded"),
                            isPresented: $showNoDownloadWarning, titleVisibility: .visible) {
            Button(String(localized: "Continue anyway")) { withAnimation { currentPage = 3 } }
            Button(String(localized: "Go back"), role: .cancel) {}
        } message: {
            Text(String(localized: "Select your countries and tap Download to get the recommended airspace, navaid and reporting-point data for navigation."))
        }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "map.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.aviationGreen)
                    .frame(width: 50, height: 50)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.aviationGreen.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Maps & Data"))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.primaryText)
                    Text(String(localized: "Download what you'll fly over — offline-ready."))
                        .font(.footnote)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                regionPill
            }
            .padding(.bottom, 16)

            openAIPDownloadCard
                .padding(.bottom, 11)

            downloadButton(
                title: String(localized: "Airports & frequencies"),
                icon: "building.2",
                isDownloading: airportDataService.isDownloading,
                progress: airportDataService.downloadProgress,
                isCompleted: airportDataService.isDataAvailable,
                action: { Task { await airportDataService.downloadData() } }
            )

            if effectiveHome == "CH" {
                downloadButton(
                    title: String(localized: "Swiss charts"),
                    icon: "map",
                    isDownloading: offlineMapManager.isDownloading,
                    progress: offlineMapManager.downloadProgress,
                    isCompleted: offlineMapManager.isCacheAvailable,
                    action: { Task { await offlineMapManager.downloadCharts(option: .icaoAndSegelflug) } }
                )
                .padding(.top, 11)
            }

            Text(String(localized: "Add more countries anytime in Settings → Data."))
                .font(.caption2)
                .foregroundColor(.dimText)
                .padding(.top, 10)

            Spacer(minLength: 16)

            HStack {
                pageDots
                Spacer()
                inlinePrimary(String(localized: "Continue"), icon: "arrow.right") {
                    if openAIPDataService.isDataAvailable {
                        withAnimation { currentPage = 3 }
                    } else {
                        showNoDownloadWarning = true
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 40)
        .task {
            if selectedCountries.isEmpty { selectedCountries = [effectiveHome] }
            await detectRegion()
        }
    }

    private var regionPill: some View {
        let name = Locale.current.localizedString(forRegionCode: effectiveHome) ?? effectiveHome
        return HStack(spacing: 6) {
            Image(systemName: "location.fill").font(.system(size: 11, weight: .semibold))
            Text(name).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundColor(.aviationGreen)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.aviationGreen.opacity(0.16)))
        .accessibilityLabel(Text(String(localized: "Detected region")) + Text(": \(name)"))
    }

    /// Recommended OpenAIP card — downloads airspace + navaids + obstacles + reporting points for the
    /// selected countries (home pre-selected, neighbours opt-in). (onboarding revamp)
    private var openAIPDownloadCard: some View {
        let anyDownloading = openAIPDataService.isDownloading || navaidService.isDownloading
            || obstacleService.isDownloading || reportingPointService.isDownloading
        let done = openAIPFullyDownloaded
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: done ? "checkmark.circle.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 19))
                    .foregroundColor(done ? .aviationGreen : .aviationGold)
                    .accessibilityHidden(true)
                Text(String(localized: "Airspace, navaids & reporting points"))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primaryText)
                Spacer()
                Text(String(localized: "Recommended"))
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.aviationGold))
            }
            countryChipRow
            HStack {
                if anyDownloading {
                    ProgressView(value: openAIPDataService.downloadProgress)
                        .tint(.aviationGold)
                        .frame(maxWidth: 160)
                }
                Spacer()
                // Green "Downloaded" only when EVERY selected country is cached; selecting a new
                // country flips it back to a gold "Download". (Maps & Data UX fix)
                Button(action: downloadOpenAIP) {
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle").font(.system(size: 14))
                        Text(done ? L10n.Onboarding.downloaded : String(localized: "Download"))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(done ? Color.aviationGreen : Color.aviationGold))
                }
                .disabled(anyDownloading || done)
                .opacity(anyDownloading ? 0.5 : 1)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke((done ? Color.aviationGreen : Color.aviationGold).opacity(0.35), lineWidth: 1))
        )
    }

    private var countryChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                countryChip(effectiveHome, isHome: true)
                ForEach(CountryNeighbors.neighbors(of: effectiveHome), id: \.self) { code in
                    Button { toggleCountry(code) } label: { countryChip(code, isHome: false) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func countryChip(_ code: String, isHome: Bool) -> some View {
        let selected = isHome || selectedCountries.contains(code)
        return Text(isHome ? "\(code) ✓" : (selected ? code : "+ \(code)"))
            .font(.caption.weight(.medium))
            .foregroundColor(selected ? .black : .secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.aviationGold : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? Color.clear : Color.white.opacity(0.22),
                                          style: StrokeStyle(lineWidth: 1, dash: isHome ? [] : [3]))
                    )
            )
    }

    private func toggleCountry(_ code: String) {
        if selectedCountries.contains(code) {
            selectedCountries.remove(code)
        } else {
            selectedCountries.insert(code)
        }
    }

    private func downloadOpenAIP() {
        var countries = selectedCountries
        countries.insert(effectiveHome)   // home is always included
        let list = Array(countries)
        Task {
            await openAIPDataService.downloadData(for: list)
            await navaidService.downloadData(for: list)
            await obstacleService.downloadData(for: list)
            await reportingPointService.downloadData(for: list)
        }
    }

    /// Best-effort GPS → ISO country (reverse geocode). Falls back silently to the device region when
    /// there's no fix or the lookup fails. (onboarding revamp)
    private func detectRegion() async {
        guard let location = locationManager.currentLocation else { return }
        let geocoder = CLGeocoder()
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let code = placemarks.first?.isoCountryCode?.uppercased() else { return }
        if code != detectedCountry {
            detectedCountry = code
            selectedCountries = [code]
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
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Claim the remaining width instead of an expanding Spacer, which squeezes the text to a
            // single character per line on a narrow (iPhone) row. (iPhone layout fix)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
