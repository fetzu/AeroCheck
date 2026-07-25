import SwiftUI
import CoreLocation

/// Settings sub-page for about info and developer options
struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var dataStatusManager: DataStatusManager
    @EnvironmentObject var locationManager: LocationManager

    @Environment(\.openURL) private var openURL

    @State private var showDeveloperOptions: Bool = false
    @State private var versionTapCount: Int = 0
    @State private var showTransactionDebug: Bool = false
    @State private var showSubscriptionLogs: Bool = false
    @State private var marketingMode: Bool = false
    @State private var simulateLSZS: Bool = false   // dev: hold a static fix at LSZS to test briefings
    @State private var previewEvent: DetectedFlightEvent?   // dev: preview the restyled event prompt

    private let tint: Color = .secondaryText

    var body: some View {
        SettingsPage {
            aboutSection
            dataSourcesSection
            replayOnboardingSection
            developerOptionsSection
        }
        .navigationTitle(L10n.Settings.about)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            marketingMode = appState.settings.marketingMode
            // Keep the section revealed if developer mode was already enabled this run (it resets on
            // relaunch), e.g. after navigating away from About and back.
            if appState.settings.developerMode { showDeveloperOptions = true }
        }
        .onChange(of: marketingMode) { _, newValue in
            appState.settings.marketingMode = newValue
            appState.saveSettings() // UX-14: persist the toggle (was a mutation with no save)
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

    // MARK: - Replay Onboarding

    /// Re-show the first-run walkthrough. Clearing the flag makes the app root (ContentView) swap to
    /// OnboardingView, which tears down the settings presentation behind it. (v4 UI/UX Revamp)
    private var replayOnboardingSection: some View {
        SettingsGroup(tint: tint, footer: L10n.Settings.replayIntroFooter) {
            SettingsButtonRow(icon: "play.circle", title: L10n.Settings.replayIntro,
                              tint: .aviationGold, showsChevron: false) {
                appState.replayOnboarding()
            }
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

    // MARK: - Data Sources

    /// Credits every external data provider the app uses (also shown on the map and in Data & Storage). (v4.1.0)
    private var dataSourcesSection: some View {
        SettingsGroup(title: L10n.DataStorage.dataSourcesTitle, tint: tint) {
            dataSourceRow(name: "swisstopo / BAZL", detail: L10n.DataStorage.sourceCharts, url: "https://www.swisstopo.admin.ch")
            dataSourceRow(name: "OpenAIP", detail: L10n.DataStorage.sourceAirspace, url: "https://www.openaip.net")
            dataSourceRow(name: "OurAirports", detail: L10n.DataStorage.sourceAirports, url: "https://ourairports.com")
            dataSourceRow(name: "MeteoSwiss", detail: L10n.DataStorage.sourceWind, url: "https://www.meteoswiss.admin.ch")
            dataSourceRow(name: "Open-Meteo", detail: L10n.DataStorage.sourceElevation, url: "https://open-meteo.com")
        }
    }

    private func dataSourceRow(name: String, detail: String, url: String) -> some View {
        SettingsButtonRow(icon: "link", title: name, subtitle: detail, tint: tint, showsChevron: false) {
            if let link = URL(string: url) { openURL(link) }
        }
    }

    /// App version + 5-tap reveal gesture. Houses the version value (and the conditional changelog
    /// link) in the same `SettingsRowLabel` idiom as the kit, with the tap counter intact.
    private var versionRow: some View {
        HStack(spacing: 10) {
            SettingsRowLabel(icon: "info.circle", title: L10n.Settings.appVersion, tint: tint)
            HStack(spacing: 4) {
                Text(appVersion)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondaryText)
                    .textSelection(.enabled)
                if !showDeveloperOptions {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
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
                    .font(.headline)
            }

            Button {
                openURL(URL(string: "https://github.com/fetzu/AeroCheck")!)
            } label: {
                HStack(spacing: 2) {
                    Text(L10n.Settings.openSourceDescription)
                        .font(.subheadline)
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                openURL(URL(string: "https://raw.githubusercontent.com/fetzu/AeroCheck/refs/heads/main/LICENSE")!)
            } label: {
                HStack(spacing: 2) {
                    Text(L10n.Settings.mitLicense)
                        .font(.subheadline)
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption2)
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
                // SEC-C37: Marketing Mode ships out of Release entirely.
                //
                // It was reachable in a shipped App Store build (five taps on the version row →
                // this section → toggle → shake → "Inject Scene"), and the scene injector is NOT
                // #if DEBUG: it calls appState.cancelFlight() with no confirmation — discarding an
                // in-progress flight's recorded track — and writes fabricated historical flights
                // into the REAL flight store via saveFlight, where they persist, appear in the
                // Flight Log as genuine entries, sync to iCloud and export as GPX/JSON. Pilots use
                // that log for currency records. The two inline comments claiming the side effects
                // are "dev-gated by the caller" were describing a RUNTIME toggle as a build gate.
                #if DEBUG
                SettingsToggleRow(icon: "megaphone", title: L10n.Settings.marketingMode,
                                  tint: tint, isOn: $marketingMode)
                #endif

                // v4.1.0: force the freshness surfaces (Home dot, nudge, on-map cue) to STALE for testing.
                SettingsToggleRow(icon: "clock.badge.xmark", title: L10n.DataStorage.simulateStaleData,
                                  tint: tint, isOn: $dataStatusManager.debugForceStale)

                // v4.1.0: hold a static GPS fix at LSZS (Samedan) so the departure briefing can be tested
                // without being at an airport. Reuses the marketing static-fix injector.
                SettingsToggleRow(icon: "location.viewfinder", title: L10n.Settings.simulateLSZS,
                                  tint: tint, isOn: Binding(
                                    get: { simulateLSZS },
                                    set: { on in
                                        simulateLSZS = on
                                        if on {
                                            locationManager.injectMarketingStaticFix(
                                                CLLocation(latitude: 46.533859, longitude: 9.883783))
                                        } else {
                                            locationManager.clearGPSStatusOverride()
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
            L10n.Settings.marketingModeDesc,
            L10n.Settings.forceNotSubscribedDesc,
            L10n.Settings.showAllTransactionsDesc,
            L10n.Settings.showSubscriptionLogsDesc,
            L10n.Settings.resetSubscriptionDesc,
            L10n.Settings.resetOnboardingDesc
        ].joined(separator: "\n")
    }
}
