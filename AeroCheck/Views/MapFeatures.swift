import Foundation

/// What a map surface draws and what a tap on it does (6.7.0, one map drawing for every surface). Every surface
/// draws with `AeroMapView` and passes its set; the pilot's map switches (`AppSettings`) apply on top, inside it:
/// a feature the surface leaves out never shows, whatever the switch.
struct MapFeatures: OptionSet, Hashable, Sendable {
    let rawValue: Int

    // What it draws
    static let airports = MapFeatures(rawValue: 1 << 0)
    static let airspace = MapFeatures(rawValue: 1 << 1)
    /// OpenAIP's raster layer.
    static let openAIPTiles = MapFeatures(rawValue: 1 << 2)
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

    /// Plan › Map, the Cockpit's MAP and the dry run: everything.
    static let navigation: MapFeatures = [.markers, .airspace, .openAIPTiles, .procedures, .route, .aircraft, .track,
                                          .trackVector, .officialChartCallout, .divertCallout, .noteCallout, .recordATO]
    /// The dry run: the navigation map without the pilot's notes, which a dry run neither shows nor writes (n7 B).
    static let dryRun: MapFeatures = navigation.subtracting(.noteCallout)
    /// The route builder: the markers, the airspace the route crosses, the procedures, the route being planned and
    /// its editing, with MapKit's dot, compass and scale. No aircraft, track or OpenAIP tiles, as before 6.7.0.
    static let builder: MapFeatures = [.markers, .airspace, .procedures, .plannedRoute, .editRoute, .addToRouteCallout,
                                       .officialChartCallout, .noteCallout, .mapKitControls]
    /// The chart alone.
    static let chartOnly: MapFeatures = []
    /// The coordinate picker: the chart under its crosshair, with MapKit's dot, compass and scale.
    static let picker: MapFeatures = [.mapKitControls]
}
