import SwiftUI
#if canImport(DeviceDiscoveryUI)
import DeviceDiscoveryUI
#endif
import WiFiAware

/// Device pairing sheet for companion mode using Wi-Fi Aware.
///
/// Both roles present a TAPPABLE button (DevicePairingView on the iPad, DevicePicker on the iPhone) —
/// the button's label is what presents Apple's system pairing/picker sheet. The user must tap it on
/// BOTH devices so each starts advertising/browsing; then they discover each other and confirm a code.
/// (A passive "waiting" label that the user never taps means that side never advertises — which is
/// exactly why pairing silently found nothing. Matches Apple's "Building peer-to-peer apps" sample.)
///
/// The order matters: the iPad taps Make discoverable first and keeps that sheet up while the iPhone
/// scans and picks it, and the copy on both screens says so. While this screen is up the manager is in
/// pairing mode (`beginPairing()` / `endPairing()`), so AéroCheck's own listener or browser leaves the
/// Wi-Fi Aware service to the pairing session. (6.1.0)
struct CompanionPairingView: View {
    @Environment(\.dismiss) var dismiss

    let role: CompanionRole

    /// Access the shared manager DIRECTLY (not `@EnvironmentObject`), so this view does NOT re-render on
    /// the manager's `@Published` churn. The `.wifiAware(.connecting(...))` provider passed to
    /// DevicePairingView/DevicePicker IS the live advertise/browse session — re-evaluating this body
    /// recreates that provider and restarts discovery before pairing can complete. Observing the manager
    /// (whose diagnostics/state publish frequently) would do exactly that. The view only CALLS the
    /// manager (logPairing), it never displays its state, so it has no reason to observe it. (v4.1 pairing fix)
    private var companionConnectivityManager: CompanionConnectivityManager { .shared }

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
        // Pairing mode for as long as this cover is up, both roles: the background listener/browser
        // stops here and auto-connect comes back when it closes (paired, cancelled, or torn down).
        .onAppear { companionConnectivityManager.beginPairing() }
        .onDisappear { companionConnectivityManager.endPairing() }
        .preferredColorScheme(.dark)
    }

    /// A tinted rounded-square companion icon (cockpit language).
    private func companionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.aero(size: 40))
            .foregroundColor(.aviationGold)
            .frame(width: 88, height: 88)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color.aviationGold.opacity(0.14)))
            .accessibilityHidden(true)
    }

    /// "Wi-Fi Aware · iOS 26+" footnote shown under the pairing prompts.
    private var wifiAwareFootnote: some View {
        Label(L10n.Companion.wifiAwareRequirement, systemImage: "wifi")
            .font(.aero(.caption))
            .foregroundColor(.dimText)
    }

    /// The gold pill that serves as the DevicePairingView/DevicePicker LABEL. Tapping it is what
    /// presents Apple's system pairing/picker sheet (and starts advertising/browsing) — so it must read
    /// as an obvious button on both roles, not a passive status line.
    private func pairButtonLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.aero(.body).weight(.semibold))
        .foregroundColor(.black)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold))
    }

    #if canImport(DeviceDiscoveryUI)
    // MARK: - Master (iPad) Pairing

    /// iPad shows DevicePairingView — its LABEL is a tappable button; tapping it presents the system
    /// pairing sheet and starts advertising. The user must tap it (and the matching button on the iPhone).
    @available(iOS 26.0, *)
    private var masterPairingContent: some View {
        VStack(spacing: 18) {
            Spacer()

            companionIcon("antenna.radiowaves.left.and.right")

            Text(L10n.Companion.pairWithiPhone)
                .font(.aero(.title3).weight(.semibold))
                .foregroundColor(.primaryText)

            // The iPad goes first: Make discoverable, sheet kept up while the iPhone scans.
            Text(L10n.Companion.pairingMasterDescription)
                .font(.aero(.subheadline))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // `.userSpecifiedDevices` = pair a NEW device via the system UI. The label below is the
            // tappable button that presents that system pairing sheet (and begins advertising).
            DevicePairingView(
                .wifiAware(.connecting(to: .aerocheck, from: .userSpecifiedDevices))
            ) {
                pairButtonLabel(icon: "antenna.radiowaves.left.and.right", title: L10n.Companion.makeDiscoverable)
            } fallback: {
                wifiAwareUnavailableContent
            }
            .padding(.top, 6)

            wifiAwareFootnote

            Spacer()
        }
        .onAppear { companionConnectivityManager.logPairing("Pairing: iPad screen open — tap '\(L10n.Companion.makeDiscoverable)'") }
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
                .font(.aero(.title3).weight(.semibold))
                .foregroundColor(.primaryText)

            // The iPhone goes second: the iPad must already be discoverable.
            Text(L10n.Companion.pairingViewerDescription)
                .font(.aero(.subheadline))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            DevicePicker(
                // `.userSpecifiedDevices` = browse for a NEW device to pair (the pairing flow). The label
                // below is the tappable button that presents the system picker (and begins browsing).
                .wifiAware(.connecting(to: .userSpecifiedDevices, from: .aerocheck))
            ) { _ in
                // A device was picked, which is not the same as paired: iOS 27 can report the pick and
                // then run the pairing (code and approval), and dismissing here can cancel that. So the
                // cover stays up; CompanionSettingsView closes it once the new pairing shows in
                // `pairedDevices`, and Cancel is there otherwise. (6.1.0)
                companionConnectivityManager.logPairing("Pairing: iPhone picked a device, waiting for the pairing to finish")
            } label: {
                pairButtonLabel(icon: "magnifyingglass", title: L10n.Companion.scanForDevices)
            } fallback: {
                wifiAwareUnavailableContent
            }
            .padding(.top, 6)

            wifiAwareFootnote

            Spacer()
        }
        .onAppear { companionConnectivityManager.logPairing("Pairing: iPhone screen open — tap '\(L10n.Companion.scanForDevices)'") }
        .onDisappear { companionConnectivityManager.logPairing("Pairing: iPhone pairing screen closed") }
    }
    #endif

    // MARK: - Fallback Content

    private var wifiAwareUnavailableContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "wifi.exclamationmark")
                .font(.aero(size: 50))
                .foregroundColor(.secondaryText)

            Text(L10n.Companion.wifiAwareUnavailable)
                .font(.aero(.headline))
                .foregroundColor(.primaryText)

            Text(L10n.Companion.wifiAwareRequirement)
                .font(.aero(.subheadline))
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
