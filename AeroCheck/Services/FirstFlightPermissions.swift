import CoreLocation
import CoreMotion
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Before your first flight (6.9.0)

/// What iOS has to ask before a first flight, on one page, once (the author's q1, 5 Nov 2026): the first time a flight is
/// planned, or at START when none ever was. Three lines of why, one Continue (App Review, 5.1.1(iv): no Skip, and it always
/// leads to iOS's box), then the boxes in a row, at a desk rather than at the aircraft. A dry run asks nothing, and nothing
/// is asked twice: a refusal stands, and Settings says what is limited.
@MainActor
final class FirstFlightPermissions {
    static let shared = FirstFlightPermissions()

    enum Item: CaseIterable, Equatable {
        case reminders, locationAlways, motion
    }

    /// Device-local, as iOS's own answers are.
    nonisolated static let shownKey = "permissions.firstFlightPageShown"

    /// Set by the app's root.
    weak var locationManager: LocationManager?
    var hasFlown: () -> Bool = { false }

    private var isAsking = false

    /// What is still iOS's to ask. Pure. Someone who has flown was asked for Always at their first START, and kept While
    /// Using: iOS wouldn't ask again, so the page doesn't promise it.
    nonisolated static func items(notifications: UNAuthorizationStatus, location: CLAuthorizationStatus,
                                  motion: CMAuthorizationStatus, hasBarometer: Bool, hasFlown: Bool) -> [Item] {
        var items: [Item] = []
        if notifications == .notDetermined { items.append(.reminders) }
        if location == .notDetermined || (location == .authorizedWhenInUse && !hasFlown) { items.append(.locationAlways) }
        if hasBarometer, motion == .notDetermined { items.append(.motion) }
        return items
    }

    /// Whether the page shows now.
    nonisolated static func showsPage(items: [Item], alreadyShown: Bool, quiet: Bool) -> Bool {
        !items.isEmpty && !alreadyShown && !quiet
    }

    /// A flight is being planned. Before the flight is created: it schedules its reminder behind the permission (review F16).
    func askWhenPlanning(_ notifications: NotificationService) async {
        guard !notifications.isInert else { return }
        if !AeroTips.isScripted { await run(notifications) }
        // Asked already, or a script running: iOS answers at once, or shows its own box as it always did.
        await notifications.requestAuthorization()
    }

    /// START, for a pilot who never planned a flight.
    func askBeforeStart() async {
        if !AeroTips.isScripted { await run(NotificationService.shared) }
    }

    private func run(_ notifications: NotificationService, defaults: UserDefaults = .standard) async {
        guard !isAsking, let locationManager else { return }
        isAsking = true
        defer { isAsking = false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let items = Self.items(notifications: settings.authorizationStatus, location: locationManager.authorizationStatus,
                               motion: CMAltimeter.authorizationStatus(),
                               hasBarometer: BarometricAltitudeService.isAvailable && BarometricAltitudeService.isPermittedByBundle,
                               hasFlown: hasFlown())
        guard Self.showsPage(items: items, alreadyShown: defaults.bool(forKey: Self.shownKey), quiet: AeroTips.quiet) else { return }
        defaults.set(true, forKey: Self.shownKey)
        await showPage(items)
        for item in items {
            switch item {
            case .reminders:
                await notifications.requestAuthorization()
            case .locationAlways:
                if locationManager.authorizationStatus == .notDetermined {
                    await answered { locationManager.requestAuthorization() }
                }
                await answered { locationManager.requestAlwaysUpgradeIfNeeded() }
            case .motion:
                let altimeter = CMAltimeter()
                await answered { altimeter.startRelativeAltitudeUpdates(to: .main) { _, _ in } }
                altimeter.stopRelativeAltitudeUpdates()
            }
        }
    }

    /// Runs `ask` and waits for iOS's box to come and go: the app leaves the active state while it is up. No box within a
    /// second and a half means iOS had nothing to ask.
    private func answered(_ ask: () -> Void) async {
        ask()
        var patience = 15
        while UIApplication.shared.applicationState == .active, patience > 0 {
            try? await Task.sleep(for: .milliseconds(100))
            patience -= 1
        }
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Over whatever is on screen, a planning sheet included. It never holds the pilot up if it can't be shown.
    private func showPage(_ items: [Item]) async {
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard let top else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                continuation.resume()
            }
            var host: UIHostingController<FirstFlightPermissionsPage>?
            let page = FirstFlightPermissionsPage(items: items) {
                host?.dismiss(animated: true) { finish() }
            }
            let controller = UIHostingController(rootView: page)
            host = controller
            controller.modalPresentationStyle = .formSheet
            controller.isModalInPresentation = true
            top.present(controller, animated: true)
            Task {
                try? await Task.sleep(for: .seconds(1))
                if controller.viewIfLoaded?.window == nil { finish() }
            }
        }
    }
}

/// The page. One way on, worded as App Review asks.
struct FirstFlightPermissionsPage: View {
    let items: [FirstFlightPermissions.Item]
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.Permissions.pageTitle)
                .font(.aero(.title2).weight(.semibold))
                .foregroundColor(.primaryText)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(items, id: \.self) { item in row(item) }
            }
            Text(L10n.Permissions.pageNext)
                .font(.aero(.footnote))
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onContinue) {
                Text(String(localized: "Continue"))
                    .font(.aero(.headline))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("permissions.continue")
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.cockpitBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissions.page")
    }

    private func row(_ item: FirstFlightPermissions.Item) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon(item))
                .font(.aero(size: 22))
                .foregroundColor(.aviationGold)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(item)).font(.aero(.headline)).foregroundColor(.primaryText)
                Text(detail(item))
                    .font(.aero(.subheadline))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(_ item: FirstFlightPermissions.Item) -> String {
        switch item {
        case .reminders: return "bell"
        case .locationAlways: return "location.fill"
        case .motion: return "barometer"
        }
    }

    private func title(_ item: FirstFlightPermissions.Item) -> String {
        switch item {
        case .reminders: return L10n.Permissions.reminders
        case .locationAlways: return L10n.Permissions.locationAlways
        case .motion: return L10n.Permissions.motion
        }
    }

    private func detail(_ item: FirstFlightPermissions.Item) -> String {
        switch item {
        case .reminders: return L10n.Permissions.remindersWhy
        case .locationAlways: return L10n.Permissions.locationAlwaysWhy
        case .motion: return L10n.Permissions.motionWhy
        }
    }
}
