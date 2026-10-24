import SwiftUI
import CoreLocation

/// Settings sub-page for about info and developer options
struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var dataStatusManager: DataStatusManager
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    @Environment(\.openURL) private var openURL

    @State private var showDeveloperOptions: Bool = false
    @State private var versionTapCount: Int = 0
    @State private var showTransactionDebug: Bool = false
    @State private var showSubscriptionLogs: Bool = false
    @State private var showSafetyNotice: Bool = false
    @State private var previewEvent: DetectedFlightEvent?   // dev: preview the restyled event prompt

    private let tint: Color = .secondaryText

    var body: some View {
        SettingsPage {
            aboutSection
            // Between ABOUT and LEGAL, under its own title, where it is found (the author, 16 Oct). (6.4.0)
            replayOnboardingSection
            legalSection
            dataSourcesSection
            developerOptionsSection
        }
        .navigationTitle(L10n.Settings.about)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Keep the section revealed if developer mode was already enabled this run (it resets on
            // relaunch), e.g. after navigating away from About and back.
            if appState.settings.developerMode { showDeveloperOptions = true }
        }
        .sheet(isPresented: $showSafetyNotice) {
            DisclaimerView(mode: .review)
        }
        .sheet(isPresented: $showTransactionDebug) {
            TransactionDebugView()
                .environmentObject(subscriptionManager)
        }
        .sheet(isPresented: $showSubscriptionLogs) {
            SubscriptionDebugLogView(debugLogger: subscriptionManager.debugLogger)
                .environmentObject(subscriptionManager)
        }
        // Dev: preview the restyled flight-event confirmation prompt without flying. (temporary)
        .overlay {
            if let event = previewEvent {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { previewEvent = nil }
                    EventConfirmationView(
                        event: event,
                        onConfirm: { previewEvent = nil },
                        onDismiss: { previewEvent = nil }
                    )
                }
            }
        }
    }

    // MARK: - Learn and practise

    /// Re-show the first-run walkthrough. Clearing the flag makes the app root (ContentView) swap to
    /// OnboardingView, which tears down the settings presentation behind it. (v4 UI/UX Revamp) Beside it, the
    /// guided flight and free practice: LEARN AND PRACTISE. (6.4.0)
    private var replayOnboardingSection: some View {
        SettingsGroup(title: L10n.DryRunCoach.learnGroup, tint: tint) {
            SettingsButtonRow(icon: "play.circle", title: L10n.Settings.replayIntro,
                              subtitle: L10n.Settings.replayIntroFooter, tint: .aviationGold, showsChevron: false) {
                appState.replayOnboarding()
            }
            // Beside the introduction (D5): the app flown on the ground, through the real screens, the whole story
            // from the plan to the logbook or one part at a time; free practice. (6.4.0)
            SettingsButtonRow(icon: "graduationcap", title: L10n.DryRunCoach.storyRow,
                              subtitle: L10n.DryRunCoach.storyRowSubtitle, tint: .aviationGold, showsChevron: false) {
                DryRunCenter.shared.requestGuided(.story)
            }
            .disabled(appState.isFlightActive)
            NavigationLink {
                DryRunPartsView()
            } label: {
                HStack(spacing: 8) {
                    SettingsRowLabel(icon: "list.number", title: L10n.DryRunCoach.partsRow, tint: .aviationGold)
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
            SettingsButtonRow(icon: "airplane.circle", title: L10n.DryRun.settingsRow,
                              subtitle: L10n.DryRun.settingsRowSubtitle, tint: .aviationGold, showsChevron: false) {
                DryRunCenter.shared.requestStart()
            }
            .disabled(appState.isFlightActive)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        SettingsGroup(title: L10n.Settings.about, tint: tint) {
            // Version row — taps here (5×) reveal Developer Options. Keeps the optional changelog
            // link in the trailing accessory until the dev options are revealed.
            versionRow

            SettingsButtonRow(icon: "globe", title: L10n.Settings.website,
                              tint: tint, value: "AeroCheck.app", showsChevron: false) {
                openURL(URL(string: "https://aerocheck.app/")!)
            }

            SettingsButtonRow(icon: "person", title: L10n.Settings.author,
                              tint: tint, value: "Julien 'fetzu' Bono", showsChevron: false) {
                openURL(URL(string: "https://www.julienbono.ch/")!)
            }

            openSourceRow
        }
    }

    // MARK: - Legal

    /// The safety notice has to stay reachable after the first-run gate is behind you — a pilot who
    /// tapped through it on day one should be able to find it again on day two, and the paywall's
    /// Terms link should not be the only route to it. Placed directly under About so it sits above
    /// the (longer) data-sources list rather than at the bottom of the page.
    private var legalSection: some View {
        SettingsGroup(title: L10n.Settings.legal, tint: tint, footer: L10n.Settings.legalFooter) {
            SettingsButtonRow(icon: "exclamationmark.triangle",
                              title: L10n.Settings.safetyNotice,
                              subtitle: L10n.Settings.safetyNoticeSubtitle,
                              tint: .aviationAmber) {
                showSafetyNotice = true
            }
            SettingsButtonRow(icon: "doc.text", title: L10n.Settings.termsOfUse,
                              tint: tint, showsChevron: false) {
                openURL(DisclaimerView.termsURL)
            }
            SettingsButtonRow(icon: "hand.raised", title: L10n.Settings.privacyPolicy,
                              tint: tint, showsChevron: false) {
                openURL(URL(string: "https://aerocheck.app/privacy")!)
            }
        }
    }

    // MARK: - Data Sources

    /// Credits every external data provider the app uses (also shown on the map and in Data & Storage). (v4.1.0)
    private var dataSourcesSection: some View {
        SettingsGroup(title: L10n.DataStorage.dataSourcesTitle, tint: tint) {
            dataSourceRow(name: "swisstopo / BAZL", detail: L10n.DataStorage.sourceCharts, url: "https://www.swisstopo.admin.ch")
            dataSourceRow(name: "OpenAIP", detail: L10n.DataStorage.sourceAirspace, url: "https://www.openaip.net")
            // open flightmaps' General Users' License asks for the credit and for a way to report errors
            // (the VFR callout's Report an error); its data is never a primary source, so the row says it
            // is indicative, as the map does. (6.2.0)
            dataSourceRow(name: "open flightmaps", detail: L10n.DataStorage.sourceVFRProcedures, url: "https://openflightmaps.org")
            dataSourceRow(name: "OurAirports", detail: L10n.DataStorage.sourceAirports, url: "https://ourairports.com")
            dataSourceRow(name: "MeteoSwiss", detail: L10n.DataStorage.sourceWind, url: "https://www.meteoswiss.admin.ch")
            // NOAA AWC is a US Government work, so METAR/TAF/SIGMET are public domain and need no
            // licence — but attribution is still the honest thing to show a pilot who is about to
            // act on an observation, alongside the two sources it is chosen over.
            dataSourceRow(name: "NOAA Aviation Weather Center", detail: L10n.DataStorage.sourceObservations, url: "https://aviationweather.gov")
            // Prepare's and the close-out's links: each country's own publishers, each named on its link as
            // some ask (SOFIA-Briefing (DGAC), MeteoAM (Aeronautica Militare)). No page of their own to open. (6.5.0)
            dataSourceRow(name: L10n.DataStorage.sourceBriefingName, detail: L10n.DataStorage.sourceBriefing, url: nil)
            // The FAA's NASR is a US Government work, public domain, and asks for no credit: given anyway, as for
            // NOAA. (6.5.0)
            dataSourceRow(name: "FAA NASR", detail: L10n.DataStorage.sourcePatterns,
                          url: "https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/")
            dataSourceRow(name: "Open-Meteo", detail: L10n.DataStorage.sourceElevation, url: "https://open-meteo.com")
            // Natural Earth is public domain and explicitly waives attribution, so this is courtesy
            // rather than obligation — but the bundled borders decide which countries a trip prefetch
            // offers, and a pilot should be able to see where that answer comes from. (v4.4.0)
            dataSourceRow(name: "Natural Earth", detail: L10n.DataStorage.sourceBorders, url: "https://www.naturalearthdata.com")
            // The typeface's licence (SIL OFL 1.1) asks for its copyright notice to travel with it; the
            // full text is bundled as OFL-B612.txt. (v6.0)
            dataSourceRow(name: "B612", detail: L10n.DataStorage.sourceTypeface, url: "https://github.com/polarsys/b612")
        }
    }

    private func dataSourceRow(name: String, detail: String, url: String?) -> some View {
        SettingsButtonRow(icon: url == nil ? "building.columns" : "link", title: name, subtitle: detail, tint: tint,
                          showsChevron: false) {
            if let url, let link = URL(string: url) { openURL(link) }
        }
        .disabled(url == nil)
    }

    /// App version + 5-tap reveal gesture. Houses the version value (and the conditional changelog
    /// link) in the same `SettingsRowLabel` idiom as the kit, with the tap counter intact.
    private var versionRow: some View {
        HStack(spacing: 10) {
            SettingsRowLabel(icon: "info.circle", title: L10n.Settings.appVersion, tint: tint)
            HStack(spacing: 4) {
                Text(appVersion)
                    .font(.aero(.subheadline).weight(.medium))
                    .foregroundColor(.secondaryText)
                    .textSelection(.enabled)
                if !showDeveloperOptions {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.aero(.caption))
                        .foregroundColor(.secondaryText)
                        .onTapGesture {
                            openURL(URL(string: "https://aerocheck.app/changelog")!)
                        }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            versionTapCount += 1
            if versionTapCount >= 5 {
                withAnimation {
                    showDeveloperOptions = true
                }
                // Enable developer mode for this run (non-persisted; resets on relaunch). Gates
                // developer-only surfaces app-wide, e.g. the Companion diagnostics panel. (v4.1)
                appState.settings.developerMode = true
            }
        }
    }

    private var openSourceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundColor(.primary)
                Text(L10n.Settings.openSource)
                    .font(.aero(.headline))
            }

            Button {
                openURL(URL(string: "https://github.com/fetzu/AeroCheck")!)
            } label: {
                HStack(spacing: 2) {
                    Text(L10n.Settings.openSourceDescription)
                        .font(.aero(.subheadline))
                    Image(systemName: "arrow.up.forward.square")
                        .font(.aero(.caption2))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                openURL(URL(string: "https://raw.githubusercontent.com/fetzu/AeroCheck/refs/heads/main/LICENSE")!)
            } label: {
                HStack(spacing: 2) {
                    Text(L10n.Settings.mitLicense)
                        .font(.aero(.subheadline))
                    Image(systemName: "arrow.up.forward.square")
                        .font(.aero(.caption2))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    // MARK: - Developer Options Section

    @ViewBuilder
    private var developerOptionsSection: some View {
        if showDeveloperOptions || appState.settings.developerMode {
            SettingsGroup(title: "Developer Options · \(L10n.Tag.dev)", tint: tint,
                          footer: developerOptionsFooter) {
                // v4.1.0: force the freshness surfaces (Home dot, nudge, on-map cue) to STALE for testing.
                SettingsToggleRow(icon: "clock.badge.xmark", title: L10n.DataStorage.simulateStaleData,
                                  tint: tint, isOn: $dataStatusManager.debugForceStale)

                // v4.1.0: hold a static GPS fix at LSZS (Samedan) so the departure briefing can be tested
                // without being at an airport. The state lives in LocationManager, which shows it
                // (orange GPS, "SIM") and ends it with the flight. (S9-25)
                SettingsToggleRow(icon: "location.viewfinder", title: L10n.Settings.simulateLSZS,
                                  tint: tint, isOn: Binding(
                                    get: { locationManager.isSimulatingPosition },
                                    set: { on in
                                        if on {
                                            locationManager.startSimulatingPosition(
                                                at: CLLocation(latitude: 46.533859, longitude: 9.883783))
                                        } else {
                                            locationManager.stopSimulatingPosition()
                                        }
                                    }))

                SettingsToggleRow(icon: "person.crop.circle.badge.xmark", title: L10n.Settings.forceNotSubscribed,
                                  tint: tint, isOn: $subscriptionManager.debugForceNotSubscribed)

                SettingsButtonRow(icon: "doc.text.magnifyingglass", title: L10n.Settings.showAllTransactions,
                                  tint: tint, showsChevron: false) {
                    showTransactionDebug = true
                }

                SettingsButtonRow(icon: "doc.text.fill", title: L10n.Settings.showSubscriptionLogs,
                                  tint: tint, showsChevron: false) {
                    showSubscriptionLogs = true
                }

                SettingsButtonRow(icon: "arrow.counterclockwise", title: L10n.Settings.resetSubscription,
                                  tint: tint, showsChevron: false, destructive: true) {
                    Task { await subscriptionManager.resetSubscriptionState() }
                }

                SettingsButtonRow(icon: "arrow.counterclockwise", title: L10n.Settings.resetOnboarding,
                                  tint: tint, showsChevron: false, destructive: true) {
                    appState.replayOnboarding()
                }

                // An escape hatch that did not exist when it was needed. Checklists cache per
                // language and survive an app update, so a stale entry could only be cleared by
                // deleting the app -- which is what it took to see the 2026-07 corrections on
                // device. Drops every cached checklist and re-resolves the active one.
                SettingsButtonRow(icon: "trash", title: "Clear checklist cache",
                                  tint: tint, showsChevron: false, destructive: true) {
                    Task {
                        aircraftDataService.clearAllChecklistCaches()
                        await aircraftDataService.fetchAvailableAircraft()
                        await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)
                    }
                }

                // Temporary: fire a sample detected event so the restyled confirmation prompt can be
                // verified without flying a pattern.
                SettingsButtonRow(icon: "bell.badge", title: "Preview event prompt",
                                  tint: tint, showsChevron: false) {
                    previewEvent = DetectedFlightEvent(type: .touchAndGo, timestamp: Date(), airport: nil,
                                                       message: "Touch-and-go detected (preview)")
                }

                // Turn developer mode back off (hides this section + the Companion diagnostics panel).
                SettingsButtonRow(icon: "xmark.circle", title: "Disable developer mode",
                                  tint: tint, showsChevron: false, destructive: true) {
                    appState.settings.developerMode = false
                    // Its tools go with it: a simulated position must not outlive the section
                    // that turns it off. (S9-25)
                    locationManager.stopSimulatingPosition()
                    withAnimation { showDeveloperOptions = false }
                }
            }
            .onChange(of: subscriptionManager.debugForceNotSubscribed) { _, _ in
                Task {
                    await subscriptionManager.updateSubscriptionStatus()
                }
            }
        }
    }

    private var developerOptionsFooter: String {
        [
            L10n.Settings.forceNotSubscribedDesc,
            L10n.Settings.showAllTransactionsDesc,
            L10n.Settings.showSubscriptionLogsDesc,
            L10n.Settings.resetSubscriptionDesc,
            L10n.Settings.resetOnboardingDesc
        ].joined(separator: "\n")
    }
}
