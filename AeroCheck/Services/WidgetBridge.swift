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
        WidgetCenter.shared.reloadAllTimelines()
    }
}
