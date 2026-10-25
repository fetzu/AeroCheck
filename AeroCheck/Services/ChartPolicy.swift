import MapKit

/// One base-chart policy for every map (6.7.0, the author's m3 A): Plan › Map, the Cockpit's MAP, the dry run, the
/// route builder and the coordinate picker draw the device's one chart choice the same way. Until 6.7.0 Plan › Map
/// and the Cockpit stopped at the glider chart (30 km on the iPad) and honoured "Force ICAO chart" and offline mode,
/// while the route builder and the picker went on to the National Map and ignored both.
///
/// - The ICAO layer: the ICAO chart, the glider chart from z11, then the National Map from z13 down to 1.5 km.
///   With "Force ICAO chart" the ICAO chart alone; in strict offline mode the downloaded charts only (the glider
///   chart when it is downloaded), enlarged past their last zoom.
/// - The chart lies over Apple's map, its satellite map under SWISSIMAGE (m1 A), except in strict offline mode,
///   where the chart replaces it: Apple's map can't be held off the network (m2 A).
struct ChartPolicy: Equatable {
    var forceICAO = false
    var strictOffline = false
    var segelflugCache = false

    /// The ICAO and glider charts' closest camera when they don't go on to the National Map (forced or offline):
    /// the glider chart's last zoom enlarged twice on the iPad (the map tile review, q3 B). (6.4.2)
    static let gliderClosestDistance: CLLocationDistance = 30_000
    /// The forced ICAO chart's closest: its last zoom, z11, a little enlarged.
    static let forcedICAOClosestDistance: CLLocationDistance = 135_000
    /// The swisstopo layers' closest, the National Map's streets.
    static let nationalMapClosestDistance: CLLocationDistance = 1_500
    /// The swisstopo layers' farthest: past it their tiles stop.
    static let chartFarthestDistance: CLLocationDistance = 600_000

    /// From the pilot's settings and the downloaded charts, as Plan › Map has always worked them out: strict offline
    /// only with the ICAO chart downloaded; offline without the glider chart, the ICAO chart alone.
    @MainActor
    static func current(settings: AppSettings, offline: OfflineMapManager) -> ChartPolicy {
        let strictOffline = settings.offlineMode && offline.isCacheAvailable
        let gliderToo = offline.isCacheAvailable && offline.isSegelflugCacheAvailable
        return ChartPolicy(forceICAO: settings.forceICAOChartLayer || (strictOffline && !gliderToo),
                           strictOffline: strictOffline, segelflugCache: offline.isSegelflugCacheAvailable)
    }

    /// The layer drawn for the pilot's choice: the ICAO chart in strict offline mode, the only one downloaded.
    func layer(for choice: MapLayerType) -> MapLayerType { strictOffline ? .icao : choice }

    /// The swisstopo chart for a layer; nil on Apple's own layers.
    func overlay(for layer: MapLayerType) -> MKTileOverlay? {
        let overlay: MKTileOverlay
        if layer == .icao {
            overlay = ICAOSegelflugkarteTileOverlay(forceICAO: forceICAO, isStrictOfflineMode: strictOffline,
                                                    hasSegelflugCache: segelflugCache, continuesToNationalMap: true)
        } else if let layerId = layer.swisstopoLayerIdentifier {
            // The National Map's white tiles outside Switzerland are no tile, for Apple's map to show. (6.4.2)
            overlay = SwisstopoTileOverlay(layerIdentifier: layerId, tileExtension: layer.tileExtension,
                                           minimumZ: layer.minimumZoom, maximumZ: layer.maximumZoom,
                                           dropsBlankTiles: layer == .landeskarten)
        } else {
            return nil
        }
        overlay.canReplaceMapContent = strictOffline
        return overlay
    }

    /// Apple's map for a layer: its own on Apple's layers, and the one under a swisstopo chart.
    static func mapType(for layer: MapLayerType) -> MKMapType {
        layer == .satellite || layer == .swissimage ? .satellite : .standard
    }

    /// How close and how far the camera goes on a layer.
    func cameraZoomRange(for layer: MapLayerType) -> MKMapView.CameraZoomRange {
        let closest: CLLocationDistance
        let farthest: CLLocationDistance
        switch layer {
        case .standard, .satellite:
            closest = 100
            farthest = 10_000_000
        case .icao:
            closest = forceICAO ? Self.forcedICAOClosestDistance
                : strictOffline ? Self.gliderClosestDistance : Self.nationalMapClosestDistance
            farthest = Self.chartFarthestDistance
        case .landeskarten, .swissimage:
            closest = Self.nationalMapClosestDistance
            farthest = Self.chartFarthestDistance
        }
        return MKMapView.CameraZoomRange(minCenterCoordinateDistance: closest, maxCenterCoordinateDistance: farthest)!
    }

    /// What the chart overlay draws, to replace it only when that changes: every new overlay asks for every tile
    /// again (the map tile review, F6). Offline and the glider cache only change the ICAO layer.
    func drawnKey(for layer: MapLayerType) -> String {
        let base = "\(layer.rawValue) offline=\(strictOffline)"
        guard layer == .icao else { return base }
        return base + " force=\(forceICAO) glider=\(strictOffline && segelflugCache)"
    }
}
