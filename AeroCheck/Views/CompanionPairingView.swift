import SwiftUI
#if canImport(DeviceDiscoveryUI)
import DeviceDiscoveryUI
#endif
import WiFiAware

/// Device pairing sheet for companion mode using Wi-Fi Aware
/// Shows the system pairing UI: DevicePairingView for master (iPad), DevicePicker for viewer (iPhone)
struct CompanionPairingView: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.dismiss) var dismiss

    let role: CompanionRole

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(DeviceDiscoveryUI)
                // Wi-Fi Aware pairing (DevicePairingView / DevicePicker) is iOS 26+ only.
                // On the iOS 17.0 deployment floor, show the unavailable state. (ARCH-09)
                if #available(iOS 26.0, *) {
                    if role == .master {
                        masterPairingContent
                    } else {
                        viewerPairingContent
                    }
                } else {
                    wifiAwareUnavailableContent
                }
                #else
                unavailableOnPlatformContent
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle(L10n.Companion.pairDevice)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// A tinted rounded-square companion icon (cockpit language).
    private func companionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 40))
            .foregroundColor(.aviationGold)
            .frame(width: 88, height: 88)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color.aviationGold.opacity(0.14)))
            .accessibilityHidden(true)
    }

    /// "Wi-Fi Aware · iOS 26+" footnote shown under the pairing prompts.
    private var wifiAwareFootnote: some View {
        Label(L10n.Companion.wifiAwareRequirement, systemImage: "wifi")
            .font(.caption)
            .foregroundColor(.dimText)
    }

    #if canImport(DeviceDiscoveryUI)
    // MARK: - Master (iPad) Pairing

    /// iPad shows DevicePairingView — waits for a companion to discover and pair
    @available(iOS 26.0, *)
    private var masterPairingContent: some View {
        // `.userSpecifiedDevices` is the PAIRING mode (the user picks a NEW device through the system UI).
        // `.selected([])` (an empty set of ALREADY-paired devices) advertises for nothing, so the iPhone
        // never discovers the iPad — the cause of the "No Devices Found / Paired devices: 0" failure.
        // (v4.1 — verified against the WiFiAware SDK + Apple's pairing sample)
        DevicePairingView(
            .wifiAware(.connecting(to: .aerocheck, from: .userSpecifiedDevices))
        ) {
            VStack(spacing: 18) {
                companionIcon("antenna.radiowaves.left.and.right")

                Text(L10n.Companion.waitingForPairing)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primaryText)

                Text(L10n.Companion.pairingMasterDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                wifiAwareFootnote.padding(.top, 4)
            }
        } fallback: {
            wifiAwareUnavailableContent
        }
        .onAppear { companionConnectivityManager.logPairing("Pairing: iPad advertising for a new device") }
        .onDisappear { companionConnectivityManager.logPairing("Pairing: iPad pairing screen closed") }
    }

    // MARK: - Viewer (iPhone) Pairing

    /// iPhone shows DevicePicker — discovers nearby iPads and lets user pick one to pair
    @available(iOS 26.0, *)
    private var viewerPairingContent: some View {
        VStack(spacing: 18) {
            Spacer()

            companionIcon("ipad.and.iphone")

            Text(L10n.Companion.pairWithiPad)
                .font(.title3.weight(.semibold))
                .foregroundColor(.primaryText)

            Text(L10n.Companion.pairingViewerDescription)
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            DevicePicker(
                // `.userSpecifiedDevices` = browse for a NEW device to pair (the pairing flow). `.selected([])`
                // browses for an empty set of already-paired devices → finds nothing. (v4.1 — SDK-verified fix)
                .wifiAware(.connecting(to: .userSpecifiedDevices, from: .aerocheck))
            ) { endpoint in
                // Pairing complete — dismiss the sheet
                // The paired device is now remembered by the system
                companionConnectivityManager.logPairing("Pairing: iPhone paired with a device")
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(L10n.Companion.scanForDevices)
                }
                .font(.body.weight(.semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold))
            } fallback: {
                wifiAwareUnavailableContent
            }
            .padding(.top, 6)

            wifiAwareFootnote

            Spacer()
        }
        .onAppear { companionConnectivityManager.logPairing("Pairing: iPhone ready to scan — tap Scan for devices") }
        .onDisappear { companionConnectivityManager.logPairing("Pairing: iPhone pairing screen closed") }
    }
    #endif

    // MARK: - Fallback Content

    private var wifiAwareUnavailableContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 50))
                .foregroundColor(.secondaryText)

            Text(L10n.Companion.wifiAwareUnavailable)
                .font(.headline)
                .foregroundColor(.primaryText)

            Text(L10n.Companion.wifiAwareRequirement)
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    #if !canImport(DeviceDiscoveryUI)
    private var unavailableOnPlatformContent: some View {
        wifiAwareUnavailableContent
    }
    #endif
}
