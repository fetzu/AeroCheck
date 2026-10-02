import SwiftUI

/// Settings sub-page for companion device mode configuration.
///
/// The pairing role (which device advertises vs browses) is derived automatically from the device
/// type — iPad drives, iPhone connects — so there is no user-facing role setting. Wi-Fi Aware pairing
/// is inherently asymmetric, so this removes the footgun where two devices could pick the same role
/// and never discover each other. (v4.1 — pairing UX simplification)
struct CompanionSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager

    @State private var enableCompanionMode: Bool = false
    @State private var isLoadingSettings: Bool = false
    @State private var showPairingSheet: Bool = false
    /// The system pairing records when the pairing screen opened (`CompanionPairingCompletion`).
    @State private var pairingBaseline: Set<UInt64> = []

    private let tint: Color = .aviationGold

    /// This device's automatic companion role (iPad = master/advertises, iPhone = viewer/browses).
    private var deviceRole: CompanionRole {
        CompanionRole.automatic(for: UIDevice.current.userInterfaceIdiom)
    }

    var body: some View {
        SettingsPage {
            enableSection
            // The paired devices whatever the toggle: pairing, pairing again and Forget need no link.
            // Shown only with Companion mode on, they were hard to reach on the iPhone, where turning it
            // on connects at once and the Companion screen takes over this page. (6.1.0)
            if enableCompanionMode || companionConnectivityManager.isWiFiAwareSupported {
                pairingSection
            }
            if enableCompanionMode {
                connectionSection
            }
            infoSection
            if appState.settings.developerMode {
                diagnosticsSection
            }
        }
        .navigationTitle(L10n.Companion.companionMode)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
            companionConnectivityManager.autoConnectIfReady()   // opening the screen = user wants it on
        }
        .onChange(of: appState.settings) { loadSettings() }
        .onChange(of: enableCompanionMode) { _, on in
            guard !isLoadingSettings else { return }
            saveSettings()
            // Connect automatically when turned on; tear down when turned off. (v4.1 companion UX)
            if on { companionConnectivityManager.autoConnectIfReady() }
            else { companionConnectivityManager.disconnect() }
        }
        // Auto-close the pairing modal once pairing succeeds, returning to this screen instead of leaving
        // the user stranded on the system "paired" sheet. (v4.1) Succeeds = a system pairing record that
        // was not there when it opened, so pairing again a device already listed closes it too. (6.1.0)
        .onChange(of: companionConnectivityManager.pairedDeviceIDs) { _, ids in
            guard showPairingSheet,
                  CompanionPairingCompletion.isComplete(baseline: pairingBaseline, current: ids) else { return }
            companionConnectivityManager.logPairing("Pairing: a new pairing record, closing the pairing screen")
            showPairingSheet = false
        }
        // Full-screen modal per Apple's DevicePicker hosting rule, and so the pairing UI lives in its own
        // presentation that a settings re-render can't tear down / restart mid-discovery. (v4.1 pairing fix)
        .fullScreenCover(isPresented: $showPairingSheet) {
            CompanionPairingView(role: deviceRole)
        }
        // SEC-C40: a paired peer asked to drive checklist/waypoint state. Being paired is not
        // authorisation — on a shared cockpit iPad the pairing may belong to a previous user —
        // so the person holding the master confirms it: for this flight, or always for a phone
        // of their own. (6.1.0)
        .modifier(CompanionCommandAuthorizationAlert(manager: companionConnectivityManager))
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
                    pairedDeviceRow(device)
                }
            }

            SettingsButtonRow(icon: "plus.circle", title: L10n.Companion.pairNewDevice,
                              tint: tint, showsChevron: false,
                              action: {
                                  pairingBaseline = companionConnectivityManager.pairedDeviceIDs
                                  showPairingSheet = true
                              })
                .disabled(!companionConnectivityManager.isWiFiAwareSupported)
        }
    }

    /// A paired device, with Forget, or Allow Again once forgotten (S9-09); and, for a phone the iPad
    /// always allows, Ask Each Flight. (6.1.0)
    ///
    /// Single line: `name` and `pairingName` are usually identical, so showing both is redundant.
    /// Prefer whichever is present. (v4.1) Wi-Fi Aware has no API to undo a system pairing, so
    /// Forget is AéroCheck's own: the device stays paired to the system but this app will not
    /// connect to it (and drops it if it is connected now).
    private func pairedDeviceRow(_ device: CompanionPairedDevice) -> some View {
        let name = device.displayName ?? L10n.Companion.unknownDevice
        let forgotten = companionConnectivityManager.isForgotten(device)
        let alwaysAllowed = !forgotten && companionConnectivityManager.isAlwaysAllowed(device)
        return HStack(spacing: 10) {
            SettingsRowLabel(icon: forgotten ? "nosign" : "checkmark.circle.fill",
                             title: name,
                             subtitle: forgotten ? L10n.Companion.deviceForgotten
                                : alwaysAllowed ? L10n.Companion.deviceAlwaysAllowed : nil,
                             tint: forgotten ? .secondaryText : .aviationGreen,
                             titleColor: forgotten ? .secondaryText : .primaryText)
            if alwaysAllowed {
                Button {
                    companionConnectivityManager.stopAlwaysAllowing(device)
                } label: {
                    Text(L10n.Companion.askEachFlight)
                        .font(.aero(.subheadline).weight(.semibold))
                        .foregroundColor(tint)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Companion.askEachFlightAccessibility(name))
            }
            Button {
                if forgotten {
                    companionConnectivityManager.allowAgain(device)
                } else {
                    companionConnectivityManager.forget(device)
                }
            } label: {
                Text(forgotten ? L10n.Companion.allowDeviceAgain : L10n.Companion.forgetDevice)
                    .font(.aero(.subheadline).weight(.semibold))
                    .foregroundColor(forgotten ? tint : .aviationRed)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(forgotten ? L10n.Companion.allowDeviceAgainAccessibility(name)
                                          : L10n.Companion.forgetDeviceAccessibility(name))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(Array(companionConnectivityManager.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.aero(.caption2, design: .monospaced))
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

/// Confirmation prompt shown on the master before a paired peer may control the flight. (SEC-C40)
///
/// Extracted as a `ViewModifier` to keep it off an already-long body chain (the same type-checker
/// budget problem the waypoint editor hit).
/// Presents the peer-command authorisation prompt. Mounted in TWO places on purpose — see the call
/// site in `ContentView` for why. Internal (not private) so the root can mount it too.
///
/// The answer is bound to the connection that asked (the request carries its generation). Allow holds
/// for this flight, reconnections included, and Always Allow on this iPad until the pilot forgets the
/// phone or chooses Ask Each Flight; a peer Wi-Fi Aware did not identify gets Allow for this
/// connection only, and no Always. Don't Allow holds for the connection, not asked again 2 s later.
/// (S9-08, S9-28; 6.1.0)
struct CompanionCommandAuthorizationAlert: ViewModifier {
    @ObservedObject var manager: CompanionConnectivityManager

    private var isPresented: Binding<Bool> {
        Binding(
            get: { manager.pendingAuthorization != nil },
            set: { presented in
                if !presented, let request = manager.pendingAuthorization {
                    manager.authorizationPromptDismissed(request)
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content.alert(L10n.Companion.allowControlTitle, isPresented: isPresented,
                      presenting: manager.pendingAuthorization) { request in
            if request.canRemember {
                Button(L10n.Companion.allowControlForFlight) {
                    manager.answerAuthorization(request, .allow)
                }
                Button(L10n.Companion.alwaysAllowControl) {
                    manager.answerAuthorization(request, .alwaysAllow)
                }
            } else {
                Button(L10n.Companion.allowControl) {
                    manager.answerAuthorization(request, .allow)
                }
            }
            Button(L10n.Companion.denyControl, role: .cancel) {
                manager.answerAuthorization(request, .deny)
            }
        } message: { request in
            Text(L10n.Companion.allowControlMessage(request.deviceName, canRemember: request.canRemember))
        }
    }
}
