import SwiftUI

/// Settings sub-page for aircraft selection, subscription, and visibility
struct AircraftSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    @State private var isSyncingAircraftData = false

    private let tint: Color = .aviationGold

    /// The Aircraft tab: the aircraft first, then its speeds, then two links: AéroCheck Pro and the
    /// aircraft visibility in Settings. Settings keeps the subscription on top and the visibility
    /// switches in full. (v6.0 · P1; on-device review #2, G-06)
    var showsSpeeds: Bool = false

    var body: some View {
        SettingsPage {
            if showsSpeeds {
                aircraftSection
                SettingsGroup(title: L10n.Sheet.speedReference, tint: .aviationGold) {
                    if let locked = lockedSelection {
                        // The speeds come with the checklist, which Pro unlocks: say that, rather
                        // than an empty table. (on-device review #4, point 1)
                        Text(L10n.Ground.speedsNeedPro(locked.registration))
                            .font(.aero(.subheadline))
                            .foregroundColor(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        // An in-flight component on a ground screen: ground screens don't switch to the
                        // night palette, so neither does the table here.
                        SpeedReferenceView(activeChecklist: appState.activeChecklist)
                            .padding(.horizontal, 14)   // the group's rows all inset 14 pt (review #1, G-06)
                            .padding(.vertical, 8)
                            .environment(\.cockpitTheme, .day)
                    }
                }
                if lockedSelection == nil {
                    SettingsGroup(title: L10n.FuelOnBoard.fuelGroup, tint: .aviationGold,
                                  footer: L10n.FuelOnBoard.fullTanksRowFooter) {
                        FullTanksSettingRow(registration: selectedRegistration)
                    }
                }
                tabLinks
            } else {
                subscriptionSection
                aircraftSection
                aircraftVisibilitySection
            }
        }
        .navigationTitle(showsSpeeds ? L10n.Ground.aircraft : L10n.Settings.aircraftAndSubscription)
        .navigationBarTitleDisplayMode(.inline)
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
            // Push the paywall into the settings stack (fills the iPad detail column / pushes on
            // iPhone) instead of presenting a sheet. (premium — iPad layout)
            NavigationLink(destination: SubscriptionView(presentedAsSheet: false)
                .environmentObject(subscriptionManager)
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.aeroCheckPro)
                            .font(.aero(.headline))
                            .foregroundColor(.primary)

                        Text(subscriptionManager.subscriptionStatus.displayText)
                            .font(.aero(.caption))
                            .foregroundColor(.secondary)

                        if subscriptionManager.isInGracePeriod,
                           let endsAt = subscriptionManager.gracePeriodEndsAt {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.aero(.caption))
                                    .foregroundColor(.aviationAmber)
                                Text(L10n.Settings.gracePeriodEnds(endsAt.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.aero(.caption2))
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

    // MARK: - Aircraft tab links

    /// On the Aircraft tab, the subscription and the visibility switches were more page than the
    /// aircraft: a line each now, one to the plans, one to the switches in Settings. (on-device review #2, G-06)
    private var tabLinks: some View {
        SettingsGroup {
            NavigationLink(destination: SubscriptionView(presentedAsSheet: false)
                .environmentObject(subscriptionManager)
            ) {
                HStack(spacing: 10) {
                    SettingsRowLabel(icon: "star.fill", title: L10n.Settings.aeroCheckPro,
                                     subtitle: proNote, tint: tint)
                    Image(systemName: "chevron.right")
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(.dimText.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SettingsButtonRow(icon: "eye", title: L10n.Settings.aircraftVisibility,
                              subtitle: L10n.Ground.visibilityInSettings, tint: tint) {
                appState.pendingSettingsSection = .aircraft
                appState.groundTab = .settings
            }
        }
    }

    /// What Pro means for this pilot now: what it unlocks, or that it's already unlocked.
    private var proNote: String {
        if subscriptionManager.subscriptionStatus.isSubscribed {
            return L10n.Settings.subscriptionAccessAll
        } else if subscriptionManager.isInGracePeriod {
            return L10n.Settings.subscriptionLapsed
        } else {
            return L10n.Ground.proUnlocksAll
        }
    }

    // MARK: - Aircraft Section

    /// Every aircraft the pilot can fly, bundled and premium, as the list to pick from. Only the bundled
    /// WT9 used to be here, with the premium ones behind "Premium aircraft", so once Today lost its
    /// carousel there was no obvious way to switch. (on-device review #1, G-06)
    private var flyableAircraft: [AircraftOption] {
        AircraftOption.flyable(remote: aircraftDataService.availableAircraft, settings: appState.settings,
                               canFly: aircraftDataService.canFly)
    }

    /// The selected aircraft, when AéroCheck Pro isn't active for it: listed, locked, and not
    /// selectable, with the way to Pro. (on-device review #4, point 1)
    private var lockedSelection: RemoteAircraftMetadata? {
        AircraftOption.lockedSelection(remote: aircraftDataService.availableAircraft, settings: appState.settings,
                                       canFly: aircraftDataService.canFly)
    }

    /// The selected aircraft's registration, bundled or premium.
    private var selectedRegistration: String {
        flyableAircraft.first { $0.isSelected(in: appState.settings) }?.registration
            ?? appState.settings.selectedAircraft.registration
    }

    private func fly(_ option: AircraftOption) {
        guard appState.selectAircraft(id: option.selectionToken, available: aircraftDataService.availableAircraft)
        else { return }
        // A premium aircraft's checklist loads now, so its speeds show below and it is ready to fly.
        if option.remoteId != nil {
            Task { await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService) }
        }
    }

    private var aircraftSection: some View {
        // The footer's Pro and refresh advice is Settings' job; the tab has its Pro line. (review #2, G-06)
        SettingsGroup(title: showsSpeeds ? L10n.Ground.yourAircraft : L10n.Settings.aircraft, tint: tint,
                      footer: showsSpeeds ? nil : L10n.Settings.aircraftFooter) {
            ForEach(flyableAircraft) { aircraft in
                let isSelected = aircraft.isSelected(in: appState.settings)
                Button(action: { fly(aircraft) }) {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.aero(size: 22))
                            .foregroundColor(isSelected ? .aviationGold : .dimText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.aero(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            Text(aircraft.modelName)
                                .font(.aero(.caption))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            ForEach(aircraft.checklistLanguages, id: \.self) { languageCode in
                                LanguageFlagView(languageCode: languageCode)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            if let locked = lockedSelection {
                lockedRow(locked)
            }

            // Premium Aircrafts navigation link
            NavigationLink(destination: PremiumAircraftListView()
                .environment(appState)
                .environmentObject(aircraftDataService)
                .environmentObject(subscriptionManager)
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(L10n.Settings.premiumAircrafts)
                                .font(.aero(.body))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            Image(systemName: "star.fill")
                                .font(.aero(.caption))
                                .foregroundColor(.aviationGold)
                        }

                        if aircraftDataService.isLoading {
                            Text(L10n.Settings.loading)
                                .font(.aero(.caption))
                                .foregroundColor(.secondary)
                        } else {
                            let premiumCount = aircraftDataService.availableAircraft.filter { !$0.isFree }.count
                            let accessibleCount = aircraftDataService.availableAircraft.filter { !$0.isFree && $0.hasAccess }.count

                            if premiumCount > 0 {
                                Text(L10n.Settings.available(accessibleCount, premiumCount))
                                    .font(.aero(.caption))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(L10n.Settings.noPremium)
                                    .font(.aero(.caption))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
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
                                .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
                                .foregroundColor(tint)
                        }
                    }
                    Text(L10n.Settings.getLatest)
                        .font(.aero(.subheadline))
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

    /// The selected premium aircraft while Pro isn't active: ticked, because it is still the one
    /// selected, but locked. A tap goes to the plans (with Restore), never selects. (review #4, point 1)
    private func lockedRow(_ aircraft: RemoteAircraftMetadata) -> some View {
        NavigationLink(destination: SubscriptionView(presentedAsSheet: false)
            .environmentObject(subscriptionManager)
        ) {
            HStack(spacing: 12) {
                Image(systemName: "lock.circle.fill")
                    .font(.aero(size: 22))
                    .foregroundColor(.aviationAmber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(aircraft.registration)
                        .font(.aero(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(L10n.Ground.proNotActiveRow)
                        .font(.aero(.caption))
                        .foregroundColor(.aviationAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(.dimText.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isSelected)
    }

    private func getLatestAircraftData() {
        isSyncingAircraftData = true
        Task {
            await subscriptionManager.syncWithServer()
            await aircraftDataService.fetchAvailableAircraft()
            // Pass the DISPLAYED language: checklists cache per language, and omitting it
            // refreshed a key nothing reads. (see syncAllChecklists)
            await aircraftDataService.syncAllChecklists(
                language: appState.settings.checklistLanguage.resolvedLanguage
            )
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
                    .font(.aero(.caption))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            } else {
                HStack(spacing: 12) {
                    Button(action: showAllAircraft) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.aero(.caption))
                            Text(L10n.Settings.showAll)
                                .font(.aero(.caption))
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
                                .font(.aero(.caption))
                            Text(L10n.Settings.hideAll)
                                .font(.aero(.caption))
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
                        .font(.aero(.caption))
                        .foregroundColor(.secondary)
                    Text(aeroclub)
                        .font(.aero(.body))
                }

                let visibleCount = visibleAircraftCount(in: aeroclub)
                Text(L10n.Settings.aircraftVisible(visibleCount, aircraftCount))
                    .font(.aero(.caption))
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
                    appState.saveSettings()
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
                    .font(.aero(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(isClubHidden ? .secondary : .primary)

                Text(aircraft.shortModelName)
                    .font(.aero(.caption))
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
                    appState.saveSettings()
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
        appState.saveSettings()
    }

    private func hideAllAircraft() {
        for group in availableAeroclubs {
            appState.settings.hiddenAeroclubs.insert(group.aeroclub)
        }
        appState.saveSettings()
    }
}

/// The selected aircraft's usable fuel with full tanks: the aircraft's figure when its data gives
/// one, otherwise the pilot's, editable here and in a flight's fuel sheet. (on-device review #4, point 3)
private struct FullTanksSettingRow: View {
    let registration: String

    @Environment(AppState.self) private var appState
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @State private var text = ""
    @FocusState private var focused: Bool

    private var resolved: FullTanks? {
        FullTanks.resolve(registration: registration, available: aircraftDataService.availableAircraft,
                          pilotValues: appState.settings.fullTanksLitres)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.FuelOnBoard.fullTanksRow)
                    .font(.aero(.body))
                    .foregroundColor(.primaryText)
                Text(resolved?.source == .aircraftData
                     ? L10n.FuelOnBoard.fromAircraftData
                     : L10n.FuelOnBoard.yourFigure(registration))
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
            }
            Spacer(minLength: 8)
            if let resolved, resolved.source == .aircraftData {
                Text("\(FuelEntry.text(resolved.litres)) L")
                    .font(.aero(.body, design: .monospaced))
                    .foregroundColor(.primaryText)
            } else {
                HStack(spacing: 6) {
                    TextField("—", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .font(.aero(.body, design: .monospaced))
                        .onSubmit(commit)
                        .accessibilityLabel(L10n.FuelOnBoard.fullTanksRow)
                    Text("L").foregroundColor(.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(width: 120, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.cockpitBackground.opacity(0.6)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .onAppear(perform: load)
        .onChange(of: registration) { _, _ in load() }
        // Saved as the field is left: the decimal pad has no return key.
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func load() {
        text = appState.settings.fullTanksLitres[FullTanks.key(for: registration) ?? ""].map(FuelEntry.text) ?? ""
    }

    private func commit() {
        guard let key = FullTanks.key(for: registration) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            guard appState.settings.fullTanksLitres[key] != nil else { return }
            appState.settings.fullTanksLitres[key] = nil
        } else {
            guard let litres = FuelEntry.litres(from: trimmed), FullTanks.isPlausible(litres) else {
                load()   // not a figure a tank holds: put back what was there
                return
            }
            guard appState.settings.fullTanksLitres[key] != litres else { return }
            appState.settings.fullTanksLitres[key] = litres
        }
        appState.saveSettings()
    }
}
