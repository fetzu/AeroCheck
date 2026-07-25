import Foundation
import WidgetKit

/// Bridges owned-aircraft state to the home-screen widget through the shared App Group, so the
/// widget renders a start button only for aircraft the user actually owns — the free bundled
/// aircraft plus any premium aircraft they have access to. An unowned premium aircraft never
/// appears as a widget button, which keeps the widget entry point access-aware. (UX-07)
///
/// The widget extension can't share code with the app, so it keeps its own copy of the App Group
/// id, the defaults key, and the `Aircraft` shape — keep them in sync with this file.
enum WidgetBridge {
    /// App Group shared with the widget extension.
    static let appGroupID = "group.com.fetzu.aerocheck"
    /// Key under which the owned-aircraft list is stored in the shared defaults.
    static let aircraftDefaultsKey = "widgetAircraft"
    /// Key under which the widget launch token is stored in the shared defaults.
    static let launchTokenDefaultsKey = "widgetLaunchToken"

    /// Secret shared with the app's own widget, proving a `start-flight` deep link came from it.
    ///
    /// SA-25: `handleDeepLink` checked only `url.scheme == "aerocheck"`, so ANY web page, iMessage,
    /// QR code or third-party app could start a flight — and with it continuous background GPS
    /// recording, since the app holds `UIBackgroundModes: [location]` and Always authorisation —
    /// from a single tap, with no confirmation and no way to tell the app's own widget from an
    /// arbitrary link.
    ///
    /// The App Group is readable only by this app and its extensions, so a web page cannot learn
    /// this value. A link without it is treated as a *request*: the aircraft is pre-selected and
    /// the user taps START, which is the confirmation.
    ///
    /// Deliberately persistent rather than short-lived: widget timelines are built ahead of time
    /// and can be rendered long after, so a rotating nonce would break the widget's one-tap start
    /// exactly when it is most wanted. The value is not a credential — the worst case for a leak
    /// is the pre-SA-25 behaviour.
    static var launchToken: String {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return "" }
        if let existing = defaults.string(forKey: launchTokenDefaultsKey), !existing.isEmpty {
            return existing
        }
        let token = UUID().uuidString
        defaults.set(token, forKey: launchTokenDefaultsKey)
        return token
    }

    /// Whether a `start-flight` deep link carries this device's widget launch token.
    static func isTrustedLaunch(token: String?) -> Bool {
        guard let token, !token.isEmpty,
              let defaults = UserDefaults(suiteName: appGroupID),
              let expected = defaults.string(forKey: launchTokenDefaultsKey), !expected.isEmpty
        else { return false }
        // Constant-time-ish comparison; these are UUID strings, not secrets worth timing, but the
        // habit costs nothing.
        return token.utf8.count == expected.utf8.count
            && zip(token.utf8, expected.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// One start button the widget can render.
    struct Aircraft: Codable, Hashable {
        let key: String          // stable deep-link token: bundled serverId or remote id
        let registration: String // display label
    }

    /// Publish the aircraft the widget should offer, given the latest remote aircraft list.
    /// Bundled (free) aircraft are always included; premium aircraft only when owned.
    static func publish(available: [RemoteAircraftMetadata]) {
        var list: [Aircraft] = []
        for type in AircraftType.allCases {
            list.append(Aircraft(key: type.serverId, registration: type.registration))
        }
        for meta in available where meta.hasAccess && !meta.isBundled {
            list.append(Aircraft(key: meta.id, registration: meta.registration))
        }

        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: aircraftDefaultsKey)
        }
        // Ensure the launch token exists before the widget next builds a timeline. (SA-25)
        _ = launchToken
        WidgetCenter.shared.reloadAllTimelines()
    }
}
