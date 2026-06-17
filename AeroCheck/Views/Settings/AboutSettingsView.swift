import SwiftUI

/// Settings sub-page for about info, available checklists, and developer options
struct AboutSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    @Environment(\.openURL) private var openURL

    @State private var showDeveloperOptions: Bool = false
    @State private var versionTapCount: Int = 0
    @State private var showTransactionDebug: Bool = false
    @State private var showSubscriptionLogs: Bool = false
    @State private var marketingMode: Bool = false

    private let tint: Color = .secondaryText

    var body: some View {
        SettingsPage {
            aboutSection
            availableChecklistsSection
            replayOnboardingSection
            developerOptionsSection
        }
        .navigationTitle(L10n.Settings.about)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            marketingMode = appState.settings.marketingMode
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
    }

    // MARK: - Replay Onboarding

    /// Re-show the first-run walkthrough. Clearing the flag makes the app root (ContentView) swap to
    /// OnboardingView, which tears down the settings presentation behind it. (Phase 3.5)
    private var replayOnboardingSection: some View {
        SettingsGroup(tint: tint, footer: L10n.Settings.replayIntroFooter) {
            SettingsButtonRow(icon: "play.circle", title: L10n.Settings.replayIntro,
                              tint: .aviationGold, showsChevron: false) {
                appState.settings.hasCompletedOnboarding = false
                appState.saveSettings()
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

    // MARK: - Available Checklists Section

    private func groupCachedAircraftByAeroclub(_ aircraft: [CachedAircraftInfo]) -> [(aeroclub: String?, aircraft: [CachedAircraftInfo])] {
        let grouped = Dictionary(grouping: aircraft) { $0.aeroclub }
        return grouped
            .map { (aeroclub: $0.key, aircraft: $0.value.sorted { $0.registration < $1.registration }) }
            .sorted { lhs, rhs in
                switch (lhs.aeroclub, rhs.aeroclub) {
                case (nil, nil): return false
                case (nil, _): return true
                case (_, nil): return false
                case (let a?, let b?): return a < b
                }
            }
    }

    private var availableChecklistsSection: some View {
        SettingsGroup(title: L10n.Settings.availableChecklists, tint: tint,
                      footer: L10n.Settings.availableChecklistsFooter) {
            let cachedAircraft = aircraftDataService.getAllCachedAircraft()
            let groupedAircraft = groupCachedAircraftByAeroclub(cachedAircraft)

            if cachedAircraft.isEmpty {
                Text(L10n.Settings.noCached)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            } else {
                ForEach(groupedAircraft, id: \.aeroclub) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let aeroclub = group.aeroclub {
                            HStack(spacing: 6) {
                                Image(systemName: "building.2")
                                    .font(.caption)
                                    .foregroundColor(.aviationGold)
                                Text(aeroclub)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.aviationGold)
                            }
                            .padding(.top, group.aeroclub == groupedAircraft.first?.aeroclub ? 0 : 8)
                        }

                        ForEach(group.aircraft) { aircraft in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(aircraft.registration)
                                        .font(.system(size: 17, weight: .semibold, design: .monospaced))

                                    if aircraft.isPremium {
                                        Image(systemName: "star.fill")
                                            .font(.caption)
                                            .foregroundColor(.aviationGold)
                                    }

                                    Text(aircraft.modelName)
                                        .foregroundColor(.secondary)

                                    Spacer()

                                    HStack(spacing: 6) {
                                        ForEach(aircraft.checklistLanguages, id: \.self) { languageCode in
                                            LanguageFlagView(languageCode: languageCode)
                                        }
                                    }
                                }
                                HStack {
                                    Text(L10n.Settings.version(aircraft.version))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(aircraft.lastUpdated)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
        }
    }

    // MARK: - Developer Options Section

    @ViewBuilder
    private var developerOptionsSection: some View {
        if showDeveloperOptions {
            SettingsGroup(title: "Developer Options · \(L10n.Tag.dev)", tint: tint,
                          footer: developerOptionsFooter) {
                SettingsToggleRow(icon: "megaphone", title: L10n.Settings.marketingMode,
                                  tint: tint, isOn: $marketingMode)

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
                    appState.settings.hasCompletedOnboarding = false
                    appState.saveSettings()
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
