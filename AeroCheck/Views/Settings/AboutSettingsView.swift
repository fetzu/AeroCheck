import SwiftUI

/// Settings sub-page for about info, available checklists, and developer options
struct AboutSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    @State private var showDeveloperOptions: Bool = false
    @State private var versionTapCount: Int = 0
    @State private var showTransactionDebug: Bool = false
    @State private var showSubscriptionLogs: Bool = false
    @State private var marketingMode: Bool = false

    var body: some View {
        Form {
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
    }

    // MARK: - Replay Onboarding

    /// Re-show the first-run walkthrough. Clearing the flag makes the app root (ContentView) swap to
    /// OnboardingView, which tears down the settings presentation behind it. (Phase 3.5)
    private var replayOnboardingSection: some View {
        Section {
            Button {
                appState.settings.hasCompletedOnboarding = false
                appState.saveSettings()
            } label: {
                Label(L10n.Settings.replayIntro, systemImage: "play.circle")
                    .foregroundColor(.aviationGold)
            }
        } footer: {
            Text(L10n.Settings.replayIntroFooter)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text(L10n.Settings.appVersion)
                    .foregroundColor(.primary)
                Spacer()
                HStack(spacing: 4) {
                    Text(appVersion)
                    if !showDeveloperOptions {
                        Link(destination: URL(string: "https://aerocheck.app/changelog")!) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                        }
                    }
                }
                .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                versionTapCount += 1
                if versionTapCount >= 5 {
                    withAnimation {
                        showDeveloperOptions = true
                    }
                }
            }

            Link(destination: URL(string: "https://aerocheck.app/")!) {
                HStack {
                    Text(L10n.Settings.website)
                        .foregroundColor(.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("AeroCheck.app")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }

            Link(destination: URL(string: "https://www.julienbono.ch/")!) {
                HStack {
                    Text(L10n.Settings.author)
                        .foregroundColor(.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Julien 'fetzu' Bono")
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundColor(.primary)
                    Text(L10n.Settings.openSource)
                        .font(.headline)
                }

                Link(destination: URL(string: "https://github.com/fetzu/AeroCheck")!) {
                    HStack(spacing: 2) {
                        Text(L10n.Settings.openSourceDescription)
                            .font(.subheadline)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }

                Link(destination: URL(string: "https://raw.githubusercontent.com/fetzu/AeroCheck/refs/heads/main/LICENSE")!) {
                    HStack(spacing: 2) {
                        Text(L10n.Settings.mitLicense)
                            .font(.subheadline)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label(L10n.Settings.about, systemImage: "info.circle.fill")
        }
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
        Section {
            let cachedAircraft = aircraftDataService.getAllCachedAircraft()
            let groupedAircraft = groupCachedAircraftByAeroclub(cachedAircraft)

            if cachedAircraft.isEmpty {
                Text(L10n.Settings.noCached)
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(groupedAircraft, id: \.aeroclub) { group in
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
            }
        } header: {
            Label(L10n.Settings.availableChecklists, systemImage: "checklist")
        } footer: {
            Text(L10n.Settings.availableChecklistsFooter)
        }
    }

    // MARK: - Developer Options Section

    @ViewBuilder
    private var developerOptionsSection: some View {
        if showDeveloperOptions {
            Section {
                Toggle(L10n.Settings.marketingMode, isOn: $marketingMode)

                Toggle(L10n.Settings.forceNotSubscribed, isOn: $subscriptionManager.debugForceNotSubscribed)
                    .onChange(of: subscriptionManager.debugForceNotSubscribed) { _, _ in
                        Task {
                            await subscriptionManager.updateSubscriptionStatus()
                        }
                    }

                Button(action: { showTransactionDebug = true }) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(L10n.Settings.showAllTransactions)
                    }
                }
                .sheet(isPresented: $showTransactionDebug) {
                    TransactionDebugView()
                        .environmentObject(subscriptionManager)
                }

                Button(action: { showSubscriptionLogs = true }) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                        Text(L10n.Settings.showSubscriptionLogs)
                    }
                }
                .sheet(isPresented: $showSubscriptionLogs) {
                    SubscriptionDebugLogView(debugLogger: subscriptionManager.debugLogger)
                        .environmentObject(subscriptionManager)
                }

                Button(role: .destructive, action: {
                    Task { await subscriptionManager.resetSubscriptionState() }
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text(L10n.Settings.resetSubscription)
                    }
                }

                Button(role: .destructive, action: {
                    appState.settings.hasCompletedOnboarding = false
                    appState.saveSettings()
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text(L10n.Settings.resetOnboarding)
                    }
                }
            } header: {
                HStack {
                    Label("Developer Options", systemImage: "hammer.fill")
                    Text(L10n.Tag.dev)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.purple)
                        )
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Settings.marketingModeDesc)
                    Text(L10n.Settings.forceNotSubscribedDesc)
                    Text(L10n.Settings.showAllTransactionsDesc)
                    Text(L10n.Settings.showSubscriptionLogsDesc)
                    Text(L10n.Settings.resetSubscriptionDesc)
                    Text(L10n.Settings.resetOnboardingDesc)
                }
            }
        }
    }
}
