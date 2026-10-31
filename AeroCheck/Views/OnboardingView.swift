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

/// First-run onboarding. Since 6.8.0 five screens, set up in about a minute and a half: welcome → location → about
/// you (base, aircraft, language) → offline data → a circuit on the ground, about three minutes, or Today. What is
/// left goes on Today's Getting started card (the author's answers on the onboarding page R4u3kJ…, 31 Oct 2026).
/// Cockpit language: gold primary actions, custom gold page dots.
///
/// The location step is App Review's (guideline 5.1.1(iv), which rejected 6.2.0): a screen shown before
/// a permission prompt has ONE way on, a button worded "Continue", and that way always leads to the
/// system's question. So no "Enable location", no "Not now", no Skip or Back on that page, and no
/// swiping past it: the pages turn by their buttons only. (6.3.2)
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    // The other OpenAIP layers download alongside airspace; observed so the card reflects all of them.
    @ObservedObject private var navaidService = OpenAIPNavaidDataService.shared
    @ObservedObject private var obstacleService = OpenAIPObstacleDataService.shared
    @ObservedObject private var reportingPointService = OpenAIPReportingPointDataService.shared
    @ObservedObject private var pilotMap = PilotMapDownloads.shared
    @ObservedObject private var countryDownloads = OfflineCountryDownloads.shared
    @State private var currentPage = 0
    /// The edge the next page slides in from: trailing going forward, leading going back.
    @State private var pageEdge: Edge = .trailing
    @State private var showSkipConfirm = false
    @State private var showNoDownloadWarning = false
    /// True while the location step is waiting for the user to answer the system permission prompt, so
    /// we advance to the next step only AFTER they've responded. (device-test feedback)
    @State private var awaitingLocationResponse = false

    /// GPS-reverse-geocoded home country (ISO-2); nil until/unless a fix resolves. (onboarding revamp)
    @State private var detectedCountry: String?
    /// The aerodrome nearest the pilot, from OpenAIP's online search, for "Based at". (6.8.0)
    @State private var nearest: NearestAerodrome.Found?
    /// The offline step's rows ticked: the country, the airports and the Atlas overview by default, the Swiss charts
    /// not (the author's answers 3 A and p3 B, 31 Oct 2026: the airports can be unticked). (6.8.0)
    @State private var offlineChoice: Set<OfflineItem> = [.country, .airports, .overview]

    /// The offline step's rows. (6.8.0)
    enum OfflineItem: Hashable { case country, airports, overview, swissCharts }

    /// Five screens since 6.8.0: welcome, location, about you, offline, a circuit on the ground (the author's answers
    /// of 31 Oct 2026 on the onboarding page R4u3kJ…: B's shape with A's download step).
    private let totalPages = 5

    /// The home country: the home aerodrome's, else the GPS-detected one, else the device region.
    private var effectiveHome: String {
        ICAOCountry.country(of: appState.settings.homeAerodromeIdent) ?? detectedCountry
            ?? (Locale.current.region?.identifier ?? "CH")
    }

    /// The home country, whole: its Atlas and its aeronautical data. No neighbours here: Settings and the route's
    /// banner offer them (the author's answer 4 B, 31 Oct 2026). (6.8.0)
    private var homeCountry: OfflineCountry? {
        OfflineCountryCatalog.countries(atlasRegions: pilotMap.regions,
                                        vfrCountries: Set(OFMDataService.shared.supportedCountries))
            .first { $0.id == effectiveHome }
    }

    private var wantedCountries: [OfflineCountry] { homeCountry.map { [$0] } ?? [] }

    private func isOnDevice(_ country: OfflineCountry) -> Bool {
        OfflineCountryCatalog.isOnDevice(country, pilotMap: pilotMap, aeronauticalKept: openAIPDataService.downloadedCountries)
    }

    /// What a country still needs, for its chip and the total.
    private func bytesToFetch(_ country: OfflineCountry) -> Int64 {
        OfflineCountryCatalog.bytesToFetch(country, downloadedRegions: Set(pilotMap.downloaded.map(\.id)),
                                           aeronauticalKept: openAIPDataService.downloadedCountries.contains(country.id))
    }

    /// How far the chosen countries' download has got, by bytes: each Atlas region as far as it has come, the
    /// aeronautical data (about 5 MB a country) once it is on the device. A bar, as Settings has (the author's device
    /// check fix2-10, 31 Oct 2026). (6.8.0)
    private var countriesProgress: Double {
        OfflineCountryCatalog.progress(wantedCountries, pilotMap: pilotMap,
                                       aeronauticalKept: openAIPDataService.downloadedCountries)
    }

    private var countriesDone: Bool { !wantedCountries.isEmpty && wantedCountries.allSatisfy(isOnDevice) }

    private var countriesDownloading: Bool {
        countryDownloads.isSyncing || wantedCountries.contains { country in
            country.atlasRegions.contains { if case .downloading = pilotMap.state(of: $0.id) { return true }; return false }
        }
    }

    var body: some View {
        ZStack {
            Color.cockpitBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Back and Skip keep their room on every page and only fade out where they don't apply,
                // so the page under them never jumps. Neither is on the location step (see above).
                HStack {
                    topBarButton(L10n.Button.back, icon: "chevron.left", isShown: currentPage >= 2) {
                        go(to: currentPage - 1)
                    }
                    Spacer()
                    topBarButton(L10n.Onboarding.skip, isShown: currentPage != 1) { showSkipConfirm = true }
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)

                // One page at a time, turned by its buttons only. The page view this replaces could be
                // swiped past the location step without its Continue, which App Review counts as putting
                // the permission off. (6.3.2)
                ZStack {
                    page(currentPage)
                        .id(currentPage)
                        .transition(.push(from: pageEdge))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(String(localized: "Skip setup?"),
                            isPresented: $showSkipConfirm, titleVisibility: .visible) {
            Button(String(localized: "Skip anyway"), role: .destructive) { completeOnboarding() }
            Button(String(localized: "Keep setting up"), role: .cancel) {}
        } message: {
            Text(L10n.Onboarding.noDataBody)
        }
        // The offline step's own words since 6.8.0: its rows are ticked already, so the way on downloads them.
        .alert(L10n.Onboarding.noDataTitle, isPresented: $showNoDownloadWarning) {
            Button(L10n.Onboarding.noDataDownload) {
                downloadChosen()
                go(to: 4)
            }
            Button(String(localized: "Continue anyway"), role: .cancel) { go(to: 4) }
        } message: {
            Text(L10n.Onboarding.noDataBody)
        }
        // Advance off the Location step only AFTER the user answers the system prompt. (device-test feedback)
        .onChange(of: locationManager.authorizationStatus) { _, status in
            if awaitingLocationResponse && status != .notDetermined {
                awaitingLocationResponse = false
                go(to: 2)
            }
        }
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0: welcomePage
        case 1: locationPage
        case 2: aboutYouPage
        case 3: offlinePage
        default: firstFlightPage
        }
    }

    /// Turn to `page`, forward from the right and back from the left. The edge is set a beat before the
    /// page changes: a leaving view keeps the transition of its last body, so changing both at once
    /// slid the first page after a change of direction the wrong way.
    private func go(to page: Int) {
        guard page != currentPage, (0..<totalPages).contains(page) else { return }
        pageEdge = page > currentPage ? .trailing : .leading
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { currentPage = page }
        }
    }

    /// Back and Skip: plain words at the top. `isShown` fades one out and takes it out of reach (and out
    /// of VoiceOver) without giving its room to the other.
    private func topBarButton(_ title: String, icon: String? = nil, isShown: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.aero(.subheadline).weight(.medium))
            }
            .foregroundColor(.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .opacity(isShown ? 1 : 0)
        .disabled(!isShown)
        .accessibilityHidden(!isShown)
        .animation(.easeInOut(duration: 0.2), value: isShown)
    }

    // MARK: - 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Spacer()

            Image("AppIconImage")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.aviationGold.opacity(0.3), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(L10n.Onboarding.welcomeHeadline)
                    .font(.aero(.title).weight(.bold))
                    .foregroundColor(.primaryText)
                    .multilineTextAlignment(.center)
            }
            // A readable width on the iPad: the headline ran from edge to edge. (6.8.0)
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)

            // One line on what the app does for a flight; the circuit on the ground at the end shows it. (6.8.0)
            Text(L10n.Onboarding.welcomeBody)
                .font(.aero(.callout))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
                .padding(.horizontal, 40)
                .padding(.top, 4)

            Spacer()

            pageDots
            primaryButton(L10n.Onboarding.getStarted, icon: "arrow.right") { go(to: 1) }
                .padding(.bottom, 40)
        }
    }

    // MARK: - 2: Location priming

    private var locationPage: some View {
        VStack(spacing: 20) {
            Spacer()

            pageIcon("location.fill", tint: .aviationGreen, iconSize: 46)
            pageTitle(String(localized: "Use your location"))

            VStack(alignment: .leading, spacing: 11) {
                locationBullet("location.fill", L10n.Onboarding.locationTrack)
                locationBullet("antenna.radiowaves.left.and.right", L10n.Onboarding.locationFrequency)
                locationBullet("house", L10n.Onboarding.locationHome)
            }
            // The list under the title on the iPad, not at the screen's edge.
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 50)

            // Says what comes next, and that the answer isn't final. Only while there is a question to
            // come: replaying onboarding later, iOS asks nothing.
            if locationManager.authorizationStatus == .notDetermined {
                Text(L10n.Onboarding.locationNext)
                    .font(.aero(.footnote))
                    .foregroundColor(.dimText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 50)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            pageDots
            // The one way on, worded as App Review asks (5.1.1(iv)): see the note on the type.
            primaryButton(String(localized: "Continue"), icon: "arrow.right") { continueFromLocation() }
                .padding(.bottom, 40)
        }
    }

    /// Ask iOS if nobody has yet, and turn the page once the pilot has answered (the `.onChange` on
    /// the authorization). Asked before, or still waiting for an answer that never came (the system
    /// can decline to show its prompt): the page simply turns, so it never holds the pilot.
    private func continueFromLocation() {
        if locationManager.authorizationStatus == .notDetermined && !awaitingLocationResponse {
            awaitingLocationResponse = true
            locationManager.requestAuthorization()
        } else {
            awaitingLocationResponse = false
            go(to: 2)
        }
    }

    // MARK: - 3: About you (6.8.0)

    /// Three answers, each already filled in: the nearest aerodrome as the base, the aircraft (the WT9 Dynamic until
    /// another is picked; a Pro one can be, marked so, and nothing asks for money here), the checklists' language.
    private var aboutYouPage: some View {
        configContainer(
            icon: "person.crop.circle", tint: .aviationGold,
            title: L10n.Onboarding.aboutYouTitle,
            subtitle: L10n.Onboarding.aboutYouSubtitle,
            page: 2
        ) {
            VStack(alignment: .leading, spacing: 11) {
                fieldLabel(L10n.Onboarding.basedAt)
                AerodromeIdentField(ident: Bindable(appState).settings.homeAerodromeIdent,
                                    suggestion: HomeAerodrome.suggestion(from: appState.flights))
                if let nearest {
                    Text(L10n.Onboarding.nearestToYou("\(nearest.ident) \(nearest.name)",
                                                      Int(nearest.distanceNM.rounded())))
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                fieldLabel(L10n.Onboarding.youFly).padding(.top, 6)
                aircraftMenu
                Text(L10n.Onboarding.aircraftNote)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                languageRow.padding(.top, 6)
            }
        }
        .task { await aircraftDataService.fetchAvailableAircraft() }
        // A fix for the nearest aerodrome and the home country, as Today warms the GPS: nothing has started it yet.
        .onAppear {
            if locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways {
                locationManager.startLocationUpdates()
            }
        }
        // Again once the first fix comes: the system's question was answered a moment ago, on the page before.
        .task(id: locationManager.currentLocation != nil) { await suggestHomeAerodrome() }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.aero(.caption).weight(.semibold))
            .tracking(1.2)
            .foregroundColor(.aviationGold)
    }

    /// The nearest aerodrome, asked of OpenAIP once the location is known, written in as the base when none is set:
    /// the pilot sees it filled in and changes it if it's wrong.
    private func suggestHomeAerodrome() async {
        guard let location = locationManager.currentLocation, nearest == nil else { return }
        // The country, for OpenAIP's list when its search around a position is refused.
        if detectedCountry == nil { await detectRegion() }
        guard let found = await NearestAerodrome.find(near: location.coordinate,
                                                      country: detectedCountry ?? Locale.current.region?.identifier)
        else { return }
        nearest = found
        if (appState.settings.homeAerodromeIdent ?? "").isEmpty {
            appState.settings.homeAerodromeIdent = found.ident
            appState.saveSettings()
        }
    }

    /// The aircraft picked: the remote one selected, else the bundled one.
    private var selectedAircraft: AircraftOption {
        if let id = appState.settings.selectedRemoteAircraftId,
           let metadata = aircraftDataService.availableAircraft.first(where: { $0.id == id }) {
            return .remote(metadata)
        }
        return .bundled(appState.settings.selectedAircraft)
    }

    /// The Pro aircraft the pilot chose without Pro: flown as the WT9 on the ground, and named in the Pro offer at
    /// the end (the author's answer p1 B, 31 Oct 2026).
    private var proAircraft: String? {
        let option = selectedAircraft
        return isPro(option) ? option.registration : nil
    }

    private func isPro(_ option: AircraftOption) -> Bool {
        if case let .remote(metadata) = option { return !metadata.isFree && !metadata.hasAccess }
        return false
    }

    /// Every aircraft, the free ones first, then each club's fleet, a Pro one marked so.
    private var aircraftMenu: some View {
        let remote = aircraftDataService.availableAircraft.filter { !$0.isBundled }
        let clubs = Dictionary(grouping: remote) { $0.aeroclub ?? "" }
        return Menu {
            ForEach(AircraftType.allCases, id: \.self) { type in
                Button("\(type.registration) · \(type.shortModelName)") {
                    _ = appState.selectAircraft(id: type.rawValue, available: aircraftDataService.availableAircraft)
                }
            }
            ForEach(clubs.keys.sorted(), id: \.self) { club in
                Section(club) {
                    ForEach(clubs[club, default: []].sorted { $0.registration < $1.registration }) { metadata in
                        Button(metadata.isFree || metadata.hasAccess
                               ? "\(metadata.registration) · \(metadata.shortModelName)"
                               : "\(metadata.registration) · \(metadata.shortModelName) · Pro") {
                            _ = appState.selectAircraft(id: metadata.id, available: aircraftDataService.availableAircraft)
                        }
                    }
                }
            }
        } label: {
            let option = selectedAircraft
            HStack(spacing: 10) {
                Text(option.registration)
                    .scaledFont(size: 15, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                Text(option.modelName)
                    .font(.aero(.subheadline))
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(isPro(option) ? "Pro" : L10n.Onboarding.free)
                    .font(.aero(.caption).weight(.semibold))
                    .foregroundColor(isPro(option) ? .aviationGold : .aviationGreen)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.aero(.caption))
                    .foregroundColor(.dimText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.Onboarding.youFly)
        .accessibilityValue("\(selectedAircraft.registration) \(selectedAircraft.modelName)")
    }

    // MARK: - 4: Offline (6.8.0)

    /// A's rows, each saying what it gives in flight and its size, each with its own progress; one Download for what
    /// is ticked. Continue never waits: the downloads run on (the author's answers 1 C, 3 A and p3 B, 31 Oct 2026).
    private var offlinePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "map.fill")
                    .scaledFont(size: 22, relativeTo: .title2)
                    .foregroundColor(.aviationGreen)
                    .frame(width: 50, height: 50)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.aviationGreen.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Onboarding.offlineTitle)
                        .font(.aero(.title3).weight(.semibold))
                        .foregroundColor(.primaryText)
                    Text(L10n.Onboarding.offlineSubtitle)
                        .font(.aero(.footnote))
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                ForEach(offlineItems, id: \.self) { item in
                    if item != offlineItems.first { Divider().background(Color.white.opacity(0.08)) }
                    offlineRow(item)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))

            HStack {
                Text(L10n.Onboarding.offlineTotal(OfflineDataView.bytes(chosenBytes)))
                    .font(.aero(.caption))
                    .foregroundColor(.dimText)
                Spacer()
                Button(action: downloadChosen) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").scaledFont(size: 14, relativeTo: .subheadline)
                        Text(String(localized: "Download")).font(.aero(.subheadline).weight(.medium))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.aviationGold))
                }
                .disabled(!hasSomethingToDownload)
                .opacity(hasSomethingToDownload ? 1 : 0.4)
            }
            .padding(.top, 12)

            Text(L10n.Onboarding.moreCountries)
                .font(.aero(.caption2))
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Spacer(minLength: 16)

            HStack {
                pageDots
                Spacer()
                inlinePrimary(String(localized: "Continue"), icon: "arrow.right") {
                    if openAIPDataService.isDataAvailable || countriesDownloading || !offlineChoice.contains(.country) {
                        go(to: 4)
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
            await pilotMap.refreshIndex()
            await detectRegion()
        }
    }

    /// The rows offered: the Swiss charts only for a Swiss base.
    private var offlineItems: [OfflineItem] {
        var items: [OfflineItem] = [.country, .airports, .overview]
        if effectiveHome == "CH" { items.append(.swissCharts) }
        return items
    }

    private enum RowState: Equatable { case idle, waiting, downloading(Double), done }

    private func rowState(_ item: OfflineItem) -> RowState {
        switch item {
        case .country:
            if countriesDone { return .done }
            return countriesDownloading ? .downloading(countriesProgress) : .idle
        case .airports:
            if airportDataService.isOurAirportsDownloaded { return .done }
            return airportDataService.isDownloading ? .downloading(airportDataService.downloadProgress) : .idle
        case .overview:
            guard let overview = pilotMap.overview else { return .idle }
            switch pilotMap.state(of: overview.id) {
            case let .downloading(fraction): return .downloading(fraction)
            case .downloaded, .updateAvailable: return .done
            default: return .idle
            }
        case .swissCharts:
            if offlineMapManager.isCacheAvailable { return .done }
            return offlineMapManager.isDownloading ? .downloading(offlineMapManager.downloadProgress) : .idle
        }
    }

    private func rowBytes(_ item: OfflineItem) -> Int64 {
        switch item {
        case .country: return homeCountry.map(bytesToFetch) ?? 0
        case .airports: return 38_000_000
        case .overview: return Int64(pilotMap.overview?.downloadBytes ?? 43_000_000)
        case .swissCharts: return 250_000_000
        }
    }

    private func rowTitle(_ item: OfflineItem) -> String {
        switch item {
        case .country: return homeCountry?.name ?? OpenAIPConfig.countryName(for: effectiveHome)
        case .airports: return L10n.OfflineData.airports
        case .overview: return L10n.Onboarding.atlasOverview
        case .swissCharts: return String(localized: "Swiss charts")
        }
    }

    private func rowDetail(_ item: OfflineItem) -> String {
        switch item {
        case .country: return L10n.Onboarding.countryDetail
        case .airports: return L10n.Onboarding.airportsDetail
        case .overview: return L10n.Onboarding.overviewDetail
        case .swissCharts: return L10n.Onboarding.swissChartsDetail
        }
    }

    private func offlineRow(_ item: OfflineItem) -> some View {
        let state = rowState(item)
        let chosen = offlineChoice.contains(item)
        return Button {
            guard state == .idle else { return }
            if chosen { offlineChoice.remove(item) } else { offlineChoice.insert(item) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state == .done ? "checkmark.circle.fill" : (chosen ? "checkmark.square.fill" : "square"))
                    .scaledFont(size: 20, relativeTo: .title3)
                    .foregroundColor(state == .done ? .aviationGreen : (chosen ? .aviationGold : .dimText))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(item))
                        .font(.aero(.subheadline).weight(.medium))
                        .foregroundColor(.primaryText)
                    switch state {
                    case .done:
                        Text(L10n.Onboarding.downloaded).font(.aero(.caption)).foregroundColor(.aviationGreen)
                    case let .downloading(fraction):
                        Text(L10n.PilotMap.downloading(fraction)).font(.aero(.caption)).foregroundColor(.secondaryText)
                        ProgressView(value: fraction).tint(.aviationGold)
                    case .waiting, .idle:
                        Text(rowDetail(item))
                            .font(.aero(.caption2))
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if state == .idle {
                    Text(OfflineDataView.bytes(rowBytes(item)))
                        .font(.aero(.caption).monospacedDigit())
                        .foregroundColor(.dimText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var chosenBytes: Int64 {
        offlineItems.filter { offlineChoice.contains($0) && rowState($0) == .idle }.reduce(0) { $0 + rowBytes($1) }
    }

    private var hasSomethingToDownload: Bool {
        offlineItems.contains { offlineChoice.contains($0) && rowState($0) == .idle }
    }

    /// Every ticked row not on the device and not downloading: each on its own, all at once.
    private func downloadChosen() {
        for item in offlineItems where offlineChoice.contains(item) && rowState(item) == .idle {
            switch item {
            case .country: downloadCountries()
            case .airports: Task { await airportDataService.downloadData() }
            case .overview: if let overview = pilotMap.overview { pilotMap.download(overview) }
            case .swissCharts: Task { await offlineMapManager.downloadCharts(option: .icaoAndSegelflug) }
            }
        }
    }

    /// The ticked rows' progress together, for the last screen.
    private var offlineProgress: Double? {
        let states = offlineItems.filter { offlineChoice.contains($0) }.map(rowState)
        guard states.contains(where: { if case .downloading = $0 { return true }; return false }) else { return nil }
        let fractions = states.map { state -> Double in
            switch state {
            case .done: return 1
            case let .downloading(fraction): return fraction
            default: return 0
            }
        }
        return fractions.reduce(0, +) / Double(max(fractions.count, 1))
    }

    // MARK: - 5: A circuit on the ground (6.8.0)

    /// The last screen: about three minutes, one circuit at the home aerodrome, three moments (a checklist, NOW and
    /// NEXT, the landing and the logbook line); or Today straight away (the author's answer p2 A, 31 Oct 2026).
    private var firstFlightPage: some View {
        VStack(spacing: 20) {
            Spacer()
            pageIcon("airplane.circle.fill", tint: .aviationGold, iconSize: 46)
            pageTitle(L10n.Onboarding.circuitTitle)
            pageBody(L10n.Onboarding.circuitBody(appState.settings.homeAerodromeIdent ?? "LSZQ"))
            if let progress = offlineProgress {
                VStack(spacing: 6) {
                    Text(L10n.Onboarding.offlineProgress(progress.formatted(.percent.precision(.fractionLength(0)))))
                        .font(.aero(.caption))
                        .foregroundColor(.dimText)
                    ProgressView(value: progress).tint(.aviationGold).frame(maxWidth: 260)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            pageDots
            VStack(spacing: 10) {
                primaryButton(L10n.Onboarding.circuitFly, icon: "airplane") {
                    completeOnboarding()
                    DryRunCenter.shared.requestFirstFlight(pro: proAircraft.map { registration in
                        (registration, { [appState] in
                            appState.pendingSettingsSection = .aircraft
                            appState.groundTab = .settings
                        })
                    })
                }
                secondaryButton(L10n.Onboarding.goToToday, icon: "arrow.right") { completeOnboarding() }
            }
            Text(L10n.Onboarding.circuitNote)
                .font(.aero(.caption2))
                .foregroundColor(.dimText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
        }
    }

    /// The home country, whole, in one sync of its aeronautical data, and every Atlas region not on the device.
    private func downloadCountries() {
        let wanted = wantedCountries
        countryDownloads.add(wanted.filter { $0.hasAeronauticalData || $0.hasVFRProcedures }.map(\.id),
                             appState: appState, airspace: openAIPDataService, navaids: navaidService)
        let here = Set(pilotMap.downloaded.map(\.id))
        for region in wanted.flatMap(\.atlasRegions) where !here.contains(region.id) {
            pilotMap.download(region)
        }
    }


    /// Best-effort GPS → ISO country (reverse geocode). Falls back silently to the device region when
    /// there's no fix or the lookup fails. (onboarding revamp)
    private func detectRegion() async {
        guard let location = locationManager.currentLocation else { return }
        let geocoder = CLGeocoder()
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let code = placemarks.first?.isoCountryCode?.uppercased() else { return }
        if code != detectedCountry { detectedCountry = code }
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
                    .scaledFont(size: 22, relativeTo: .title2)
                    .foregroundColor(tint)
                    .frame(width: 50, height: 50)
                    .background(RoundedRectangle(cornerRadius: 15).fill(tint.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.aero(.title3).weight(.semibold))
                        .foregroundColor(.primaryText)
                    Text(subtitle)
                        .font(.aero(.footnote))
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
                    go(to: page + 1)
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
            .scaledFont(size: iconSize, relativeTo: .largeTitle)
            .foregroundColor(tint)
            .frame(width: 88, height: 88)
            .background(RoundedRectangle(cornerRadius: 24).fill(tint.opacity(0.14)))
            .accessibilityHidden(true)
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(.aero(.title).weight(.bold))
            .foregroundColor(.primaryText)
            .multilineTextAlignment(.center)
    }

    private func pageBody(_ text: String) -> some View {
        Text(text)
            .font(.aero(.callout))
            .foregroundColor(.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func locationBullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.aviationGreen)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.aero(.callout))
                .foregroundColor(.primaryText)
            Spacer(minLength: 0)
        }
    }

    /// Full-width checklist-language row with a compact Auto / EN / FR segmented control.
    private var languageRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "globe")
                .scaledFont(size: 19, relativeTo: .title3)
                .foregroundColor(.altimeterBlue)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Checklist language"))
                    .font(.aero(.subheadline).weight(.medium))
                    .foregroundColor(.primaryText)
                Text(String(localized: "Auto follows your device language"))
                    .font(.aero(.caption2))
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(ChecklistLanguage.availableLanguages) { lang in
                    Button { appState.settings.checklistLanguage = lang } label: {
                        Text(langShort(lang))
                            .font(.aero(.caption).weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundColor(appState.settings.checklistLanguage == lang ? .black : .secondaryText)
                            .padding(.horizontal, 11)
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
            // Keep the whole segmented control at its natural width so the title VStack yields space to
            // it instead of squeezing the segments into "Au/to". (iPhone language-selector fix)
            .fixedSize()
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
                    .font(.aero(.body).weight(.semibold))
                Image(systemName: icon)
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
                    .accessibilityHidden(true)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold))
        }
        .padding(.horizontal, 40)
    }

    /// Full-width grey button — same size as `primaryButton`, for a neutral secondary action (no
    /// dark-pattern tiny "skip"). (device-test feedback)
    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.aero(.body).weight(.semibold))
                Image(systemName: icon)
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
                    .accessibilityHidden(true)
            }
            .foregroundColor(.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.14), lineWidth: 1))
            )
        }
        .padding(.horizontal, 40)
    }

    /// Compact gold button for the config steps' footer.
    private func inlinePrimary(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.aero(.body).weight(.semibold))
                Image(systemName: icon)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
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
        // Localized so VoiceOver reads the page count in the user's language (FR). (v4.1.1 a11y pass)
        .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(totalPages)"))
    }

    private func downloadButton(
        title: String,
        icon: String,
        isDownloading: Bool,
        progress: Double,
        isCompleted: Bool,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            if !isDownloading && !isCompleted {
                action()
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : icon)
                    .scaledFont(size: 20, relativeTo: .title3)
                    .foregroundColor(isCompleted ? .aviationGreen : .aviationGold)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.aero(.subheadline).weight(.medium))
                        .foregroundColor(.primaryText)

                    if isDownloading {
                        ProgressView(value: progress)
                            .tint(.aviationGold)
                    } else if isCompleted {
                        Text(L10n.Onboarding.downloaded)
                            .font(.aero(.caption))
                            .foregroundColor(.aviationGreen)
                    } else if let detail {
                        Text(detail)
                            .font(.aero(.caption2))
                            .foregroundColor(.dimText)
                    }
                }

                Spacer()

                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if !isCompleted {
                    Image(systemName: "arrow.down.circle")
                        .scaledFont(size: 20, relativeTo: .title3)
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
        // What is left goes on Today's Getting started card, the Pro aircraft chosen without Pro with it. (6.8.0)
        GettingStarted.begin(proAircraft: proAircraft)
        appState.completeOnboarding()
    }
}
