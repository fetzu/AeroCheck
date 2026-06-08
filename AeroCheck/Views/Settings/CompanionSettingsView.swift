import SwiftUI

/// Settings sub-page for companion device mode configuration
struct CompanionSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager

    @State private var enableCompanionMode: Bool = false
    @State private var companionRole: CompanionRoleSetting = .auto
    @State private var isLoadingSettings: Bool = false
    @State private var showPairingSheet: Bool = false

    var body: some View {
        Form {
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
        Section {
            Toggle(L10n.Companion.enableCompanionMode, isOn: $enableCompanionMode)
        } footer: {
            Text(L10n.Companion.enableDescription)
        }
    }

    // MARK: - Role Section

    private var roleSection: some View {
        Section {
            Picker(L10n.Companion.deviceRole, selection: $companionRole) {
                ForEach(CompanionRoleSetting.allCases) { role in
                    Text(role.displayName).tag(role)
                }
            }
        } footer: {
            Text(resolvedRoleDescription)
        }
    }

    // MARK: - Pairing Section

    private var pairingSection: some View {
        Section(L10n.Companion.pairedDevices) {
            if companionConnectivityManager.pairedDevices.isEmpty {
                HStack {
                    Image(systemName: "ipad.and.iphone")
                        .foregroundColor(.secondary)
                    Text(L10n.Companion.noPairedDevices)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(companionConnectivityManager.pairedDevices) { device in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.aviationGreen)
                        VStack(alignment: .leading) {
                            Text(device.name ?? L10n.Companion.unknownDevice)
                                .foregroundColor(.primary)
                            if let pairingName = device.pairingName {
                                Text(pairingName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Button(action: { showPairingSheet = true }) {
                HStack {
                    Image(systemName: "plus.circle")
                    Text(L10n.Companion.pairNewDevice)
                }
            }
            .disabled(!companionConnectivityManager.isWiFiAwareSupported)
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        Section(L10n.Companion.connection) {
            switch companionConnectivityManager.connectionState {
            case .disconnected:
                disconnectedRow

            case .pairing:
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(L10n.Companion.pairing)
                        .foregroundColor(.secondary)
                }

            case .connecting:
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(L10n.Companion.connecting)
                        .foregroundColor(.secondary)
                }

            case .connected:
                connectedRow

            case .reconnecting:
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text(L10n.Companion.reconnecting)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private var disconnectedRow: some View {
        Group {
            let resolvedRole = companionRole.resolvedRole(for: UIDevice.current.userInterfaceIdiom)
            if companionConnectivityManager.hasPairedDevices {
                if resolvedRole == .viewer {
                    Button(action: {
                        companionConnectivityManager.connectToPairedDevice()
                    }) {
                        HStack {
                            Image(systemName: "link")
                            Text(L10n.Companion.connectToiPad)
                        }
                    }
                } else {
                    Button(action: {
                        companionConnectivityManager.startListening()
                    }) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(L10n.Companion.startListening)
                        }
                    }
                }
            } else {
                Text(L10n.Companion.pairDeviceFirst)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var connectedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.aviationGreen)
                Text(L10n.Companion.connected)
                    .foregroundColor(.aviationGreen)
            }
            if let deviceName = companionConnectivityManager.connectedDeviceName {
                Text(String(format: L10n.Companion.connectedTo, deviceName))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(role: .destructive, action: {
                companionConnectivityManager.disconnect()
            }) {
                Text(L10n.Companion.disconnect)
            }
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(L10n.Companion.wifiAwareInfo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: "wifi")
                        .foregroundColor(.secondary)
                }
                Label {
                    Text(L10n.Companion.noNetworkRequired)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.secondary)
                }
            }
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
