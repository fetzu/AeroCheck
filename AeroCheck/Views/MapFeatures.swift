import Foundation

/// What a map surface draws and what a tap on it does (6.7.0, one map drawing for every surface). Every surface
/// draws with `AeroMapView` and passes its set; the pilot's map switches (`AppSettings`) apply on top, inside it:
/// a feature the surface leaves out never shows, whatever the switch.
struct MapFeatures: OptionSet, Hashable, Sendable {
    let rawValue: Int

    // What it draws
    static let airports = MapFeatures(rawValue: 1 << 0)
    static let airspace = MapFeatures(rawValue: 1 << 1)
    /// The tags that say the limits of the airspace that matters now (`AirspaceRelevance`): the Cockpit's map. (6.9.0)
    static let airspaceTags = MapFeatures(rawValue: 1 << 2)
    /// The limits along the airspace's boundaries: Plan › Map, the route builder, ALL LIMITS. (6.9.0)
    static let airspaceLabels = MapFeatures(rawValue: 1 << 19)
    /// A tap with no marker under it: every airspace over the point (`AirspaceStackCard`). (6.9.0)
    static let airspaceCard = MapFeatures(rawValue: 1 << 20)
    static let navaids = MapFeatures(rawValue: 1 << 3)
    static let obstacles = MapFeatures(rawValue: 1 << 4)
    static let reportingPoints = MapFeatures(rawValue: 1 << 5)
    /// Traffic circuits, VFR routes and sectors (`VFRMapLayer`).
    static let procedures = MapFeatures(rawValue: 1 << 6)
    /// The active route, its waypoints and a diversion's line.
    static let route = MapFeatures(rawValue: 1 << 7)
    static let aircraft = MapFeatures(rawValue: 1 << 8)
    /// The flown track.
    static let track = MapFeatures(rawValue: 1 << 9)
    static let trackVector = MapFeatures(rawValue: 1 << 10)

    // What a tap does
    /// The official chart in an aerodrome's or a procedure's callout.
    static let officialChartCallout = MapFeatures(rawValue: 1 << 11)
    /// "Divert here" in an aerodrome's callout, in flight with a route.
    static let divertCallout = MapFeatures(rawValue: 1 << 12)
    /// The pilot's note in an aerodrome's callout.
    static let noteCallout = MapFeatures(rawValue: 1 << 13)
    /// A tap or a long press on a waypoint records its time over, in flight.
    static let recordATO = MapFeatures(rawValue: 1 << 14)
    /// MapKit's own location dot, compass and scale, for a surface without the app's map chrome.
    static let mapKitControls = MapFeatures(rawValue: 1 << 15)
    /// The route being planned, its numbered pins and its selected leg (`PlannedRoute`).
    static let plannedRoute = MapFeatures(rawValue: 1 << 16)
    /// Press and hold to move a planned waypoint, insert one on a leg or add one; a tap on a pin selects it.
    static let editRoute = MapFeatures(rawValue: 1 << 17)
    /// "+" in an aerodrome's, navaid's or reporting point's callout adds it to the planned route.
    static let addToRouteCallout = MapFeatures(rawValue: 1 << 18)

    static let markers: MapFeatures = [.airports, .navaids, .obstacles, .reportingPoints]

    /// Plan › Map: everything, the limits along the boundaries.
    static let navigation: MapFeatures = [.markers, .airspace, .airspaceLabels, .airspaceCard, .procedures, .route, .aircraft,
                                          .track, .trackVector, .officialChartCallout, .divertCallout, .noteCallout, .recordATO]
    /// The Cockpit's MAP: the same with tags. One style per screen, and it never changes in the air (a9 A).
    static let cockpit: MapFeatures = navigation.subtracting(.airspaceLabels).union(.airspaceTags)
    /// The dry run: the Cockpit's map without the pilot's notes, which a dry run neither shows nor writes (n7 B).
    static let dryRun: MapFeatures = cockpit.subtracting(.noteCallout)
    /// ALL LIMITS turned on, on either: the boundary labels instead of the tags (a10 A).
    func showingAllLimits() -> MapFeatures { subtracting(.airspaceTags).union(.airspaceLabels) }
    /// The route builder: the markers, the airspace the route crosses with its limits, the procedures, the route being
    /// planned and its editing, with MapKit's dot, compass and scale. No aircraft or track, as before 6.7.0.
    static let builder: MapFeatures = [.markers, .airspace, .airspaceLabels, .procedures, .plannedRoute, .editRoute,
                                       .addToRouteCallout, .officialChartCallout, .noteCallout, .mapKitControls]
    /// The chart alone.
    static let chartOnly: MapFeatures = []
    /// The coordinate picker: the chart under its crosshair, with MapKit's dot, compass and scale.
    static let picker: MapFeatures = [.mapKitControls]
}
