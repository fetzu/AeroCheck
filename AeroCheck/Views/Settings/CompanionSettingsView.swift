import SwiftUI

/// Settings sub-page for companion device mode configuration
struct CompanionSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager

    @State private var enableCompanionMode: Bool = false
    @State private var companionRole: CompanionRoleSetting = .auto
    @State private var isLoadingSettings: Bool = false
    @State private var showPairingSheet: Bool = false

    private let tint: Color = .aviationGold

    var body: some View {
        SettingsPage {
            enableSection
            if enableCompanionMode {
                roleSection
                pairingSection
                connectionSection
            }
            infoSection
        }
        .navigationTitle(L10n.Companion.companionMode)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { loadSettings() }
        .onChange(of: enableCompanionMode) { if !isLoadingSettings { saveSettings() } }
        .onChange(of: companionRole) { if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showPairingSheet) {
            CompanionPairingView(role: companionRole.resolvedRole(for: UIDevice.current.userInterfaceIdiom))
                .environmentObject(companionConnectivityManager)
        }
    }

    // MARK: - Enable Section

    private var enableSection: some View {
        // When Wi-Fi Aware isn't available (iOS 17–25, or incompatible hardware), say so explicitly
        // instead of letting the user toggle into a silently inert configuration.
        let footer = companionConnectivityManager.isWiFiAwareSupported
            ? L10n.Companion.enableDescription
            : L10n.Companion.requiresIOS26
        return SettingsGroup(title: nil, tint: tint, footer: footer) {
            SettingsToggleRow(icon: "ipad.and.iphone", title: L10n.Companion.enableCompanionMode,
                              tint: tint, isOn: $enableCompanionMode)
        }
    }

    // MARK: - Role Section

    private var roleSection: some View {
        SettingsGroup(title: nil, tint: tint, footer: resolvedRoleDescription.isEmpty ? nil : resolvedRoleDescription) {
            SettingsMenuRow(icon: "person.2", title: L10n.Companion.deviceRole,
                            tint: tint, selection: $companionRole) {
                ForEach(CompanionRoleSetting.allCases) { role in
                    Text(role.displayName).tag(role)
                }
            }
        }
    }

    // MARK: - Pairing Section

    private var pairingSection: some View {
        SettingsGroup(title: L10n.Companion.pairedDevices, tint: tint) {
            if companionConnectivityManager.pairedDevices.isEmpty {
                SettingsValueRow(icon: "ipad.and.iphone", title: L10n.Companion.noPairedDevices,
                                 tint: tint, value: "")
            } else {
                ForEach(companionConnectivityManager.pairedDevices) { device in
                    SettingsRowLabel(icon: "checkmark.circle.fill",
                                     title: device.name ?? L10n.Companion.unknownDevice,
                                     subtitle: device.pairingName,
                                     tint: .aviationGreen)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }
            }

            SettingsButtonRow(icon: "plus.circle", title: L10n.Companion.pairNewDevice,
                              tint: tint, showsChevron: false,
                              action: { showPairingSheet = true })
                .disabled(!companionConnectivityManager.isWiFiAwareSupported)
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        SettingsGroup(title: L10n.Companion.connection, tint: tint) {
            switch companionConnectivityManager.connectionState {
            case .disconnected:
                disconnectedRow

            case .pairing:
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(L10n.Companion.pairing)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

            case .connecting:
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(L10n.Companion.connecting)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

            case .connected:
                connectedRow

            case .reconnecting:
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(L10n.Companion.reconnecting)
                        .foregroundColor(.orange)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private var disconnectedRow: some View {
        Group {
            let resolvedRole = companionRole.resolvedRole(for: UIDevice.current.userInterfaceIdiom)
            if companionConnectivityManager.hasPairedDevices {
                if resolvedRole == .viewer {
                    SettingsButtonRow(icon: "link", title: L10n.Companion.connectToiPad,
                                      tint: tint, showsChevron: false,
                                      action: { companionConnectivityManager.connectToPairedDevice() })
                } else {
                    SettingsButtonRow(icon: "antenna.radiowaves.left.and.right", title: L10n.Companion.startListening,
                                      tint: tint, showsChevron: false,
                                      action: { companionConnectivityManager.startListening() })
                }
            } else {
                SettingsValueRow(icon: "exclamationmark.circle", title: L10n.Companion.pairDeviceFirst,
                                 tint: tint, value: "")
            }
        }
    }

    private var connectedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRowLabel(icon: "checkmark.circle.fill",
                             title: L10n.Companion.connected,
                             subtitle: companionConnectivityManager.connectedDeviceName.map { String(format: L10n.Companion.connectedTo, $0) },
                             tint: .aviationGreen,
                             titleColor: .aviationGreen)
            Button(role: .destructive, action: {
                companionConnectivityManager.disconnect()
            }) {
                Text(L10n.Companion.disconnect)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        SettingsGroup(title: nil, tint: tint) {
            SettingsRowLabel(icon: "wifi", title: L10n.Companion.wifiAwareInfo, tint: tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            SettingsRowLabel(icon: "wifi.slash", title: L10n.Companion.noNetworkRequired, tint: tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    // MARK: - Helpers

    private var resolvedRoleDescription: String {
        let resolved = companionRole.resolvedRole(for: UIDevice.current.userInterfaceIdiom)
        switch resolved {
        case .master:
            return L10n.Companion.roleDescriptionMaster
        case .viewer:
            return L10n.Companion.roleDescriptionViewer
        case .none:
            return ""
        }
    }

    private func loadSettings() {
        isLoadingSettings = true
        enableCompanionMode = appState.settings.enableCompanionMode
        companionRole = appState.settings.companionRole
        isLoadingSettings = false
    }

    private func saveSettings() {
        appState.settings.enableCompanionMode = enableCompanionMode
        appState.settings.companionRole = companionRole
        appState.saveSettings()
    }
}

// MARK: - CompanionRoleSetting Display

extension CompanionRoleSetting {
    var displayName: String {
        switch self {
        case .auto: return L10n.Companion.roleAuto
        case .primary: return L10n.Companion.rolePrimary
        case .companion: return L10n.Companion.roleCompanion
        }
    }
}
