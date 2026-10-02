import SwiftUI
import UIKit
#if canImport(DeviceDiscoveryUI)
import DeviceDiscoveryUI
#endif
import WiFiAware

/// Device pairing sheet for companion mode using Wi-Fi Aware.
///
/// Both roles present a TAPPABLE button (the system pairing screen on the iPad, DevicePicker on the iPhone):
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
        .onAppear {
            CompanionPairingSession.devicePicked = false
            companionConnectivityManager.beginPairing()
        }
        .onDisappear { companionConnectivityManager.endPairing() }
        .task { await closeWhenTheSystemScreenIsDone() }
        .preferredColorScheme(.dark)
    }

    /// Close this cover once the system pairing screen it opened has come and gone: the pairing is then
    /// over, done or cancelled, and closing ends pairing mode, which brings the link back.
    ///
    /// Pairing again two devices already paired adds no new pairing record on iOS 27, so the record rule
    /// (`CompanionPairingCompletion`, in CompanionSettingsView) never fired. Both covers stayed up and the
    /// iPad kept the link paused until Companion mode was toggled there (6.1.0 device check, 2 Oct 2026).
    /// The iPhone closes only after a device was picked: a picker dismissed without a pick leaves the
    /// cover up for another try. The system screen is whatever is presented over this cover; if the
    /// system shows it outside the app's windows, nothing is seen and Cancel remains. (6.1.0)
    private func closeWhenTheSystemScreenIsDone() async {
        var cover: UIViewController?
        var systemScreenSeen = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard let top = Self.frontViewController(), !top.isBeingPresented else { continue }
            guard let cover else {
                cover = top   // the first settled look: the cover itself, nothing over it yet
                continue
            }
            let systemScreenUp = top !== cover
            if systemScreenUp, !systemScreenSeen {
                systemScreenSeen = true
                companionConnectivityManager.logPairing("Pairing: the system pairing screen is up")
            } else if !systemScreenUp, systemScreenSeen {
                systemScreenSeen = false
                guard role == .master || CompanionPairingSession.devicePicked else {
                    companionConnectivityManager.logPairing("Pairing: the picker closed with no device picked")
                    continue
                }
                companionConnectivityManager.logPairing("Pairing: the system pairing screen closed, closing the pairing screen")
                dismiss()
                return
            }
        }
    }

    /// The front-most view controller of the key window: this cover's, or whatever is presented over it.
    static func frontViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
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

    /// What the screen does to the link, and when it goes away: the link is paused while it is up
    /// (pairing mode), and it closes by itself once a pairing record lands, pairing again a device
    /// already listed included. Without it, re-pairing read as stuck, then worked "somehow". (6.1.0)
    private var pairingPausesLinkNote: some View {
        Text(L10n.Companion.pairingPausesLink)
            .font(.aero(.footnote))
            .foregroundColor(.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }

    /// "Wi-Fi Aware · iOS 26+" footnote shown under the pairing prompts.
    private var wifiAwareFootnote: some View {
        Label(L10n.Companion.wifiAwareRequirement, systemImage: "wifi")
            .font(.aero(.caption))
            .foregroundColor(.dimText)
    }

    /// The gold pill of both roles' pairing button (the iPad's Make discoverable, the iPhone's DevicePicker
    /// label). Tapping it is what presents Apple's system pairing/picker screen (and starts
    /// advertising/browsing), so it must read as an obvious button, not a passive status line.
    static func pairButtonLabel(icon: String, title: String) -> some View {
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

    /// iPad: a "Make discoverable" button that presents the system pairing screen and starts
    /// advertising. The user must tap it (and the matching button on the iPhone).
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

            // The system pairing screen as one UIKit controller, made on the tap and presented from
            // UIKit, not SwiftUI's DevicePairingView: see `CompanionAdvertiserPresenter`. (6.1.0)
            if CompanionAdvertiserPresenter.isSupported {
                Button {
                    CompanionAdvertiserPresenter.present()
                } label: {
                    Self.pairButtonLabel(icon: "antenna.radiowaves.left.and.right", title: L10n.Companion.makeDiscoverable)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            } else {
                wifiAwareUnavailableContent
            }

            pairingPausesLinkNote

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

            // In its own sub-view that SwiftUI skips when this screen redraws: see `CompanionPickerButton`.
            CompanionPickerButton()
                .equatable()
                .padding(.top, 6)

            pairingPausesLinkNote

            wifiAwareFootnote

            Spacer()
        }
        .onAppear { companionConnectivityManager.logPairing("Pairing: iPhone screen open — tap '\(L10n.Companion.scanForDevices)'") }
        .onDisappear { companionConnectivityManager.logPairing("Pairing: iPhone pairing screen closed") }
    }
    #endif

    // MARK: - Fallback Content

    private var wifiAwareUnavailableContent: some View { Self.unavailableContent }

    /// Wi-Fi Aware unavailable here (the simulator, older hardware). Static so the picker's sub-view can show it.
    static var unavailableContent: some View {
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

/// What the pairing screen needs to know of the system picker it hosts. Not observed: the cover's body must
/// not redraw on it (see `CompanionPairingView`). (6.1.0)
@MainActor
enum CompanionPairingSession {
    /// The iPhone picked a device in the system picker since the pairing screen opened.
    static var devicePicked = false
}

#if canImport(DeviceDiscoveryUI)
/// The iPhone's "Scan for Devices": SwiftUI's `DevicePicker`, alone in a view that compares equal to itself,
/// so a redraw of the pairing screen above it (state the manager publishes, the system picker taking the
/// foreground) doesn't rebuild the picker. Its browser provider IS the live Wi-Fi Aware subscribe, and on
/// iOS 27 a rebuild restarts the system picker's scene (seen in the 2 Oct 2026 device logs), which a
/// pairing in progress doesn't survive. There is no UIKit picker for Wi-Fi Aware to use instead
/// (`DDDevicePickerViewController` takes an `NWBrowser.Descriptor`, which has no Wi-Fi Aware case). (6.1.0)
@available(iOS 26.0, *)
private struct CompanionPickerButton: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        DevicePicker(
            // `.userSpecifiedDevices` = browse for a NEW device to pair (the pairing flow). The label
            // below is the tappable button that presents the system picker (and begins browsing).
            .wifiAware(.connecting(to: .userSpecifiedDevices, from: .aerocheck))
        ) { _ in
            // A device was picked, which is not the same as paired: iOS 27 can report the pick and
            // then run the pairing (code and approval), and dismissing here can cancel that. So the
            // cover stays up; it closes once the new pairing shows in `pairedDevices`
            // (CompanionSettingsView) or once the system picker has closed after this pick
            // (`closeWhenTheSystemScreenIsDone`), and Cancel is there otherwise. (6.1.0)
            CompanionPairingSession.devicePicked = true
            CompanionConnectivityManager.shared.logPairing("Pairing: iPhone picked a device, waiting for the pairing to finish")
        } label: {
            CompanionPairingView.pairButtonLabel(icon: "magnifyingglass", title: L10n.Companion.scanForDevices)
        } fallback: {
            CompanionPairingView.unavailableContent
        }
    }
}

/// Presents the iPad's system pairing screen ("Make discoverable") as ONE `DDDevicePairingViewController`,
/// made on the tap and presented from UIKit.
///
/// Why not SwiftUI's `DevicePairingView`: on iPadOS 27 it built the system screen twice within ~40 ms of
/// the tap (two hosted scenes). Starting the second cancelled the first's discovery ("Invalidating existing
/// discovery before starting new one"), and tearing the first scene down then invalidated the second's, so
/// the `_aerocheck._udp` publish lived a few milliseconds ("Terminating NANPublish … because its client was
/// invalidated") and the iPhone found no device. Seen in both devices' system logs, 2 Oct 2026 (6.1.0 device
/// check). A view controller we create once has no SwiftUI update to rebuild it.
///
/// Presented as a form sheet so the pairing cover underneath stays in the hierarchy: it keeps pairing mode
/// on (`beginPairing()` / `endPairing()` hang on the cover's appear/disappear), and closing the cover once
/// the new device shows in `pairedDevices` takes this sheet down with it.
@available(iOS 26.0, *)
@MainActor
enum CompanionAdvertiserPresenter {
    /// A NEW device, chosen in the system UI (`.userSpecifiedDevices`), on our publishable service.
    private static var listener: WAPublisherListener {
        .wifiAware(.connecting(to: .aerocheck, from: .userSpecifiedDevices))
    }

    /// False where Wi-Fi Aware isn't available (the simulator, older hardware): the cover shows its
    /// unavailable state instead of the button.
    static var isSupported: Bool { DDDevicePairingViewController.isSupported(listener) }

    /// The screen on show, so a second tap doesn't stack another one (UIKit holds it while presented).
    private static weak var current: DDDevicePairingViewController?

    static func present() {
        let manager = CompanionConnectivityManager.shared
        if let current, current.presentingViewController != nil {
            manager.logPairing("Pairing: iPad pairing screen already up")
            return
        }
        guard let presenter = CompanionPairingView.frontViewController() else {
            manager.logPairing("Pairing: no screen to present the iPad pairing screen from")
            return
        }
        let controller = DDDevicePairingViewController(listenerProvider: listener, access: .default)
        controller.modalPresentationStyle = .formSheet
        current = controller
        manager.logPairing("Pairing: iPad discoverable, system pairing screen up")
        presenter.present(controller, animated: true)
    }
}
#endif
