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
    }

    #if canImport(DeviceDiscoveryUI)
    // MARK: - Master (iPad) Pairing

    /// iPad shows DevicePairingView — waits for a companion to discover and pair
    @available(iOS 26.0, *)
    private var masterPairingContent: some View {
        DevicePairingView(
            .wifiAware(.connecting(to: .aerocheck, from: .selected([])))
        ) {
            VStack(spacing: 24) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationGold)

                Text(L10n.Companion.waitingForPairing)
                    .font(.headline)
                    .foregroundColor(.primaryText)

                Text(L10n.Companion.pairingMasterDescription)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } fallback: {
            wifiAwareUnavailableContent
        }
    }

    // MARK: - Viewer (iPhone) Pairing

    /// iPhone shows DevicePicker — discovers nearby iPads and lets user pick one to pair
    @available(iOS 26.0, *)
    private var viewerPairingContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 60))
                .foregroundColor(.aviationGold)

            Text(L10n.Companion.pairWithiPad)
                .font(.headline)
                .foregroundColor(.primaryText)

            Text(L10n.Companion.pairingViewerDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            DevicePicker(
                .wifiAware(.connecting(to: .selected([]), from: .aerocheck))
            ) { endpoint in
                // Pairing complete — dismiss the sheet
                // The paired device is now remembered by the system
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(L10n.Companion.scanForDevices)
                }
                .font(.headline)
                .foregroundColor(.cockpitBackground)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.aviationGold)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } fallback: {
                wifiAwareUnavailableContent
            }

            Spacer()
        }
    }
    #endif

    // MARK: - Fallback Content

    private var wifiAwareUnavailableContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text(L10n.Companion.wifiAwareUnavailable)
                .font(.headline)
                .foregroundColor(.primaryText)

            Text(L10n.Companion.wifiAwareRequirement)
                .font(.subheadline)
                .foregroundColor(.secondary)
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
