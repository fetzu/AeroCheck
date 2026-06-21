import SwiftUI

/// Settings sub-page for companion device mode configuration.
///
/// The pairing role (which device advertises vs browses) is derived automatically from the device
/// type — iPad drives, iPhone connects — so there is no user-facing role setting. Wi-Fi Aware pairing
/// is inherently asymmetric, so this removes the footgun where two devices could pick the same role
/// and never discover each other. (v4.1 — pairing UX simplification)
struct CompanionSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager

    @State private var enableCompanionMode: Bool = false
    @State private var isLoadingSettings: Bool = false
    @State private var showPairingSheet: Bool = false

    private let tint: Color = .aviationGold

    /// This device's automatic companion role (iPad = master/advertises, iPhone = viewer/browses).
    private var deviceRole: CompanionRole {
        CompanionRole.automatic(for: UIDevice.current.userInterfaceIdiom)
    }

    var body: some View {
        SettingsPage {
            enableSection
            if enableCompanionMode {
                pairingSection
                connectionSection
            }
            infoSection
            if appState.settings.developerMode {
                diagnosticsSection
            }
        }
        .navigationTitle(L10n.Companion.companionMode)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { loadSettings() }
        .onChange(of: enableCompanionMode) { if !isLoadingSettings { saveSettings() } }
        // Full-screen modal per Apple's DevicePicker hosting rule, and so the pairing UI lives in its own
        // presentation that a settings re-render can't tear down / restart mid-discovery. (v4.1 pairing fix)
        .fullScreenCover(isPresented: $showPairingSheet) {
            CompanionPairingView(role: deviceRole)
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

    // MARK: - Pairing Section

    private var pairingSection: some View {
        // The role is automatic, so the footer just tells the user what THIS device does and what to do
        // on the other one — no role to choose.
        SettingsGroup(title: L10n.Companion.pairedDevices, tint: tint, footer: pairingGuidance) {
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

    /// One-line guidance naming what this device does and what to do on the other one.
    private var pairingGuidance: String {
        deviceRole == .master ? L10n.Companion.pairingGuidanceMaster : L10n.Companion.pairingGuidanceViewer
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        SettingsGroup(title: L10n.Companion.connection, tint: tint) {
            switch companionConnectivityManager.connectionState {
            case .disconnected:
                disconnectedRow

            case .pairing:
                progressRow(L10n.Companion.pairing, color: .secondary)

            case .connecting:
                progressRow(L10n.Companion.connecting, color: .secondary)

            case .connected:
                connectedRow

            case .reconnecting:
                progressRow(L10n.Companion.reconnecting, color: .orange)
            }
        }
    }

    private func progressRow(_ text: String, color: Color) -> some View {
        HStack {
            ProgressView()
                .padding(.trailing, 8)
            Text(text)
                .foregroundColor(color)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var disconnectedRow: some View {
        Group {
            if companionConnectivityManager.hasPairedDevices {
                if deviceRole == .viewer {
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

    // MARK: - Diagnostics Section (developer mode)

    private var diagnosticsSection: some View {
        SettingsGroup(title: "\(L10n.Companion.diagnostics) · \(L10n.Tag.dev)", tint: tint,
                      footer: L10n.Companion.diagnosticsFooter) {
            SettingsValueRow(icon: "wifi", title: L10n.Companion.diagWifiAware, tint: tint,
                             value: companionConnectivityManager.isWiFiAwareSupported ? L10n.Companion.diagSupported : L10n.Companion.diagUnsupported)
            SettingsValueRow(icon: deviceRole == .master ? "ipad" : "iphone",
                             title: L10n.Companion.diagThisDevice, tint: tint,
                             value: deviceRoleDescription)
            SettingsValueRow(icon: "point.3.connected.trianglepath.dotted",
                             title: L10n.Companion.diagConnection, tint: tint,
                             value: connectionStateDescription)
            SettingsValueRow(icon: "ipad.and.iphone", title: L10n.Companion.pairedDevices, tint: tint,
                             value: "\(companionConnectivityManager.pairedDevices.count)")
            SettingsValueRow(icon: "number", title: L10n.Companion.diagService, tint: tint,
                             value: companionConnectivityManager.serviceName)

            eventLog

            SettingsButtonRow(icon: "doc.on.doc", title: L10n.Companion.diagCopy,
                              tint: tint, showsChevron: false,
                              action: copyDiagnostics)
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            if companionConnectivityManager.diagnostics.isEmpty {
                Text(L10n.Companion.diagNoEvents)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(Array(companionConnectivityManager.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceRoleDescription: String {
        deviceRole == .master ? L10n.Companion.diagRoleMaster : L10n.Companion.diagRoleViewer
    }

    private var connectionStateDescription: String {
        switch companionConnectivityManager.connectionState {
        case .disconnected: return L10n.Companion.disconnected
        case .pairing: return L10n.Companion.pairing
        case .connecting: return L10n.Companion.connecting
        case .connected: return L10n.Companion.connected
        case .reconnecting: return L10n.Companion.reconnecting
        }
    }

    private func copyDiagnostics() {
        let header = """
        AéroCheck companion diagnostics
        Wi-Fi Aware supported: \(companionConnectivityManager.isWiFiAwareSupported)
        This device: \(deviceRoleDescription)
        Connection: \(connectionStateDescription)
        Paired devices: \(companionConnectivityManager.pairedDevices.count)
        Service: \(companionConnectivityManager.serviceName)
        ---
        """
        UIPasteboard.general.string = header + "\n" + companionConnectivityManager.diagnostics.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func loadSettings() {
        isLoadingSettings = true
        enableCompanionMode = appState.settings.enableCompanionMode
        isLoadingSettings = false
    }

    private func saveSettings() {
        appState.settings.enableCompanionMode = enableCompanionMode
        appState.saveSettings()
    }
}
