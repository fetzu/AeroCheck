import SwiftUI

/// Settings sub-page for aircraft selection, subscription, and visibility
struct AircraftSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    @State private var selectedAircraft: AircraftType = .wt9Dynamic
    @State private var showSubscriptionView = false
    @State private var isSyncingAircraftData = false
    @State private var isLoadingSettings = false

    private let tint: Color = .aviationGold

    var body: some View {
        SettingsPage {
            subscriptionSection
            aircraftSection
            aircraftVisibilitySection
        }
        .navigationTitle(L10n.Settings.aircraftAndSubscription)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSubscriptionView) {
            SubscriptionView()
                .environmentObject(subscriptionManager)
        }
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: selectedAircraft) { _, _ in if !isLoadingSettings { saveSettings() } }
    }

    // MARK: - Subscription Section

    private var subscriptionFooter: String {
        if subscriptionManager.subscriptionStatus.isSubscribed {
            return L10n.Settings.subscriptionAccessAll
        } else if subscriptionManager.isInGracePeriod {
            return L10n.Settings.subscriptionLapsed
        } else {
            return L10n.Settings.subscriptionUnlockText
        }
    }

    private var subscriptionSection: some View {
        SettingsGroup(title: L10n.Settings.subscription, tint: tint, footer: subscriptionFooter) {
            Button(action: { showSubscriptionView = true }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.aeroCheckPro)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text(subscriptionManager.subscriptionStatus.displayText)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if subscriptionManager.isInGracePeriod,
                           let endsAt = subscriptionManager.gracePeriodEndsAt {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundColor(.aviationAmber)
                                Text(L10n.Settings.gracePeriodEnds(endsAt.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.caption2)
                                    .foregroundColor(.aviationAmber)
                            }
                        }
                    }

                    Spacer()

                    if subscriptionManager.subscriptionStatus.isSubscribed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.aviationGreen)
                    } else if subscriptionManager.isInGracePeriod {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.aviationAmber)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Aircraft Section

    private var aircraftSection: some View {
        SettingsGroup(title: L10n.Settings.aircraft, tint: tint, footer: L10n.Settings.aircraftFooter) {
            // Bundled aircraft (F-HVXA only)
            ForEach(AircraftType.allCases) { aircraft in
                Button(action: {
                    selectedAircraft = aircraft
                    appState.settings.selectedRemoteAircraftId = nil
                    saveSettings()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            Text(aircraft.shortModelName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            ForEach(aircraft.checklistLanguages, id: \.self) { languageCode in
                                LanguageFlagView(languageCode: languageCode)
                            }
                        }

                        if selectedAircraft == aircraft && appState.settings.selectedRemoteAircraftId == nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.aviationGold)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Premium Aircrafts navigation link
            NavigationLink(destination: PremiumAircraftListView(showSubscriptionView: $showSubscriptionView)
                .environmentObject(appState)
                .environmentObject(aircraftDataService)
                .environmentObject(subscriptionManager)
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(L10n.Settings.premiumAircrafts)
                                .font(.system(.body))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundColor(.aviationGold)
                        }

                        if aircraftDataService.isLoading {
                            Text(L10n.Settings.loading)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            let premiumCount = aircraftDataService.availableAircraft.filter { !$0.isFree }.count
                            let accessibleCount = aircraftDataService.availableAircraft.filter { !$0.isFree && $0.hasAccess }.count

                            if premiumCount > 0 {
                                Text(L10n.Settings.available(accessibleCount, premiumCount))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(L10n.Settings.noPremium)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.dimText.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Get latest aircraft data button
            Button(action: getLatestAircraftData) {
                HStack(spacing: 13) {
                    ZStack {
                        Circle().fill(tint.opacity(0.16)).frame(width: 34, height: 34)
                        if isSyncingAircraftData {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(tint)
                        }
                    }
                    Text(L10n.Settings.getLatest)
                        .font(.subheadline)
                        .foregroundColor(.primaryText)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSyncingAircraftData)
        }
    }

    private func getLatestAircraftData() {
        isSyncingAircraftData = true
        Task {
            await subscriptionManager.syncWithServer()
            await aircraftDataService.fetchAvailableAircraft()
            await aircraftDataService.syncAllChecklists()
            await MainActor.run {
                isSyncingAircraftData = false
            }
        }
    }

    // MARK: - Aircraft Visibility Section

    private var availableAeroclubs: [(aeroclub: String, aircraft: [RemoteAircraftMetadata])] {
        let accessibleAircraft = aircraftDataService.availableAircraft.filter { $0.hasAccess && !$0.isBundled }
        let grouped = Dictionary(grouping: accessibleAircraft) { $0.aeroclub ?? "" }
        return grouped
            .filter { !$0.key.isEmpty }
            .map { (aeroclub: $0.key, aircraft: $0.value.sorted { $0.registration < $1.registration }) }
            .sorted { $0.aeroclub < $1.aeroclub }
    }

    private var aircraftVisibilitySection: some View {
        SettingsGroup(title: L10n.Settings.aircraftVisibility, tint: tint, footer: L10n.Settings.aircraftVisibilityFooter) {
            if availableAeroclubs.isEmpty {
                Text(L10n.Settings.noAircraftToFilter)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            } else {
                HStack(spacing: 12) {
                    Button(action: showAllAircraft) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.caption)
                            Text(L10n.Settings.showAll)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.aviationGreen.opacity(0.2))
                        .foregroundColor(.aviationGreen)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button(action: hideAllAircraft) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                                .font(.caption)
                            Text(L10n.Settings.hideAll)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.aviationRed.opacity(0.2))
                        .foregroundColor(.aviationRed)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                ForEach(availableAeroclubs, id: \.aeroclub) { group in
                    DisclosureGroup {
                        ForEach(group.aircraft) { aircraft in
                            aircraftVisibilityToggle(for: aircraft)
                        }
                    } label: {
                        aeroclubVisibilityHeader(for: group.aeroclub, aircraftCount: group.aircraft.count)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .tint(tint)
                }
            }
        }
    }

    private func aeroclubVisibilityHeader(for aeroclub: String, aircraftCount: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "building.2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(aeroclub)
                        .font(.body)
                }

                let visibleCount = visibleAircraftCount(in: aeroclub)
                Text(L10n.Settings.aircraftVisible(visibleCount, aircraftCount))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { !appState.settings.hiddenAeroclubs.contains(aeroclub) },
                set: { isVisible in
                    if isVisible {
                        appState.settings.hiddenAeroclubs.remove(aeroclub)
                    } else {
                        appState.settings.hiddenAeroclubs.insert(aeroclub)
                    }
                    saveSettings()
                }
            ))
            .labelsHidden()
            .tint(.aviationGold)
        }
    }

    private func aircraftVisibilityToggle(for aircraft: RemoteAircraftMetadata) -> some View {
        let isClubHidden = appState.settings.hiddenAeroclubs.contains(aircraft.aeroclub ?? "")

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(aircraft.registration)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(isClubHidden ? .secondary : .primary)

                Text(aircraft.shortModelName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { !appState.settings.hiddenAircraftIds.contains(aircraft.id) && !isClubHidden },
                set: { isVisible in
                    if isVisible {
                        appState.settings.hiddenAircraftIds.remove(aircraft.id)
                        if let club = aircraft.aeroclub {
                            appState.settings.hiddenAeroclubs.remove(club)
                        }
                    } else {
                        appState.settings.hiddenAircraftIds.insert(aircraft.id)
                    }
                    saveSettings()
                }
            ))
            .labelsHidden()
            .tint(.aviationGold)
            .disabled(isClubHidden)
        }
        .padding(.leading, 16)
        .opacity(isClubHidden ? 0.5 : 1.0)
    }

    private func visibleAircraftCount(in aeroclub: String) -> Int {
        guard let group = availableAeroclubs.first(where: { $0.aeroclub == aeroclub }) else { return 0 }
        if appState.settings.hiddenAeroclubs.contains(aeroclub) {
            return 0
        }
        return group.aircraft.filter { !appState.settings.hiddenAircraftIds.contains($0.id) }.count
    }

    private func showAllAircraft() {
        appState.settings.hiddenAircraftIds.removeAll()
        appState.settings.hiddenAeroclubs.removeAll()
        saveSettings()
    }

    private func hideAllAircraft() {
        for group in availableAeroclubs {
            appState.settings.hiddenAeroclubs.insert(group.aeroclub)
        }
        saveSettings()
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        selectedAircraft = appState.settings.selectedAircraft
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.selectedAircraft = selectedAircraft
        appState.saveSettings()
    }
}
