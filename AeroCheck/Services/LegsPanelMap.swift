import CoreGraphics
import CoreLocation
import MapKit

/// What the nav map does while the legs-and-frequencies panel is open (6.1, option C, the author's
/// choice): the map's own controls go, the chart left between the next-waypoint card and the panel
/// (the band) frames the aircraft and where it is going, and closing the panel puts the map back as
/// it was.
///
/// The band is a look of a few seconds at the kneeboard: a frequency, the next ETA, and the aircraft
/// against the route while at it. It is a view, not a map to work in, so nothing on it moves the
/// camera but the aircraft.
///
/// Pure: the map views draw the answers, they don't work them out.
enum LegsPanelMap {

    // MARK: - Chrome

    /// The map's chrome for a panel state. The next-waypoint card, the check slot, MARK, START LEG,
    /// Routes, Divert and More are not the map's: they stay where they are, open or closed.
    struct Chrome: Equatable {
        /// Map (base chart and overlays), North up / Track up, Centre, − and +.
        var showsMapControls: Bool
        /// CACHED (or OFFLINE) and the scale bar.
        var showsMapStatus: Bool
        /// "Route 12 NM 264 · Show": a way to move the camera, like Centre.
        var showsRouteOffScreenPill: Bool
        /// The next-waypoint card (or line, on the phone): the map's one in-flight readout.
        var showsNextWaypoint: Bool
        /// The undo after a MARK, so a mis-tap can still be taken back with the panel open.
        var showsUndoToast: Bool
        /// A tap on the band closes the panel; pans, pinches, rotations and the markers do nothing.
        var bandClosesPanel: Bool

        static func forPanel(open: Bool) -> Chrome {
            Chrome(showsMapControls: !open, showsMapStatus: !open, showsRouteOffScreenPill: !open,
                   showsNextWaypoint: true, showsUndoToast: true, bandClosesPanel: open)
        }
    }

    // MARK: - The band

    /// The panel's band, as the map view is given it.
    struct Band: Equatable {
        /// The chart left in view, in the map view's own points: under the card, over the panel. nil
        /// until the chart has been laid out with the panel open (the first pass still has it closed).
        var rect: CGRect?
        /// The map view's size, as laid out with the panel open.
        var viewSize: CGSize
        /// nil without a position fix: the camera then stays where it is.
        var aircraft: CLLocationCoordinate2D?
        /// The next waypoint (the diversion field when diverting, the waypoint previewed from the leg
        /// table while one is); nil with no route.
        var waypoint: CLLocationCoordinate2D?
        /// 0 in North up, the track in Track up.
        var heading: CLLocationDirection

        static func == (a: Band, b: Band) -> Bool {
            a.rect == b.rect && a.viewSize == b.viewSize && a.heading == b.heading
                && same(a.aircraft, b.aircraft) && same(a.waypoint, b.waypoint)
        }

        private static func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return a.latitude == b.latitude && a.longitude == b.longitude
            default: return false
            }
        }
    }

    /// The band in the map view's points, from what the chart measured in its own: the chart's size,
    /// the bottom of the chrome at its top (the card), the map view's frame (larger than the chart where
    /// it runs under a safe area) and how much of the chart's foot the panel covers (in landscape it
    /// lies over the chart; elsewhere it is under it, and the inset is 0).
    static func bandRect(chartSize: CGSize, chromeBottom: CGFloat, mapFrame: CGRect,
                         panelInset: CGFloat) -> CGRect {
        let top = min(max(0, chromeBottom), chartSize.height)
        let bottom = max(top, chartSize.height - max(0, panelInset))
        return CGRect(x: -mapFrame.minX, y: top - mapFrame.minY, width: chartSize.width, height: bottom - top)
    }

    // MARK: - Framing

    /// How the band shows the aircraft.
    enum Framing: Equatable {
        /// No route, or no next waypoint: the aircraft in the middle of the band.
        case aircraftAlone
        /// The aircraft and the next waypoint both in the band, at the pilot's zoom or as little
        /// farther out as it takes.
        case aircraftAndWaypoint
        /// The waypoint more than `farFactor` bands away: the aircraft at the band's edge, the route
        /// running across it towards the waypoint, at the pilot's zoom. Kept until the waypoint fits
        /// at that zoom or another one comes up, so the map doesn't zoom out and back as the aircraft
        /// closes in.
        case routeAhead
    }

    struct Placement: Equatable {
        /// The camera's centre, which MapKit puts in the middle of the map view (of its safe area): off
        /// the band's middle by as much as the card and the panel make it.
        var center: MKMapPoint
        /// How much farther out than the pilot's zoom: 1 is their zoom.
        var zoomOut: Double
        var framing: Framing

        static func == (a: Placement, b: Placement) -> Bool {
            a.center.x == b.center.x && a.center.y == b.center.y && a.zoomOut == b.zoomOut
                && a.framing == b.framing
        }
    }

    /// Room kept between the band's edges and the aircraft or the waypoint's marker (both about 30 pt).
    static let margin: CGFloat = 28
    /// Past this many bands away, the waypoint isn't worth zooming out for. (The proposal's "about 3×".)
    static let farFactor: Double = 3

    /// Where the camera goes so the band frames the aircraft and the waypoint.
    /// - Parameters:
    ///   - cameraPoint: where MapKit puts the camera's centre in the view, the middle of the view's safe
    ///     area (nil: of the view). A map view running under a safe area has it off the middle.
    ///   - scale: the pilot's zoom, in map points per screen point.
    ///   - previous: the framing on the last pass, which `routeAhead` keeps.
    static func place(aircraft: MKMapPoint, waypoint: MKMapPoint?, heading: CLLocationDirection,
                      band: CGRect, viewSize: CGSize, cameraPoint: CGPoint? = nil, scale: Double,
                      previous: Framing?) -> Placement {
        let viewCenter = cameraPoint ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let inner = innerBand(band, viewSize: viewSize)
        let middle = CGPoint(x: inner.midX, y: inner.midY)

        guard let waypoint else {
            return Placement(center: center(putting: aircraft, at: middle, viewCenter: viewCenter,
                                            scale: scale, heading: heading),
                             zoomOut: 1, framing: .aircraftAlone)
        }

        // The waypoint seen from the aircraft, on screen at the pilot's zoom.
        let offset = toScreen(dx: waypoint.x - aircraft.x, dy: waypoint.y - aircraft.y, heading: heading)
        let ahead = CGVector(dx: offset.dx / scale, dy: offset.dy / scale)
        // How much farther out the two would need to fit, side by side in the band.
        let needed = max(abs(ahead.dx) / max(inner.width, 1), abs(ahead.dy) / max(inner.height, 1))

        let framing: Framing
        if previous == .routeAhead && needed > 1 {
            framing = .routeAhead
        } else if needed > farFactor {
            framing = .routeAhead
        } else {
            framing = .aircraftAndWaypoint
        }

        switch framing {
        case .routeAhead:
            // The longest line across a rectangle in a direction runs through its middle: the aircraft
            // goes where that line leaves the band behind it, so as much of the route as the band can
            // hold runs ahead of it. A waypoint straight ahead puts the aircraft low in the band.
            let length = hypot(ahead.dx, ahead.dy)
            let ux = ahead.dx / length, uy = ahead.dy / length
            let reach = min(abs(ux) > 1e-9 ? inner.width / 2 / abs(ux) : .infinity,
                            abs(uy) > 1e-9 ? inner.height / 2 / abs(uy) : .infinity)
            let spot = CGPoint(x: middle.x - ux * reach, y: middle.y - uy * reach)
            return Placement(center: center(putting: aircraft, at: spot, viewCenter: viewCenter,
                                            scale: scale, heading: heading),
                             zoomOut: 1, framing: .routeAhead)
        default:
            let zoomOut = max(1, needed)
            let midpoint = MKMapPoint(x: (aircraft.x + waypoint.x) / 2, y: (aircraft.y + waypoint.y) / 2)
            return Placement(center: center(putting: midpoint, at: middle, viewCenter: viewCenter,
                                            scale: scale * zoomOut, heading: heading),
                             zoomOut: zoomOut, framing: .aircraftAndWaypoint)
        }
    }

    /// Where a point of the map lands in the view, for a camera centre, zoom (map points per screen
    /// point) and heading. MapKit's own sum: the centre at `cameraPoint` (the middle of the view, of its
    /// safe area), the map turned so the heading points up.
    static func screenPoint(of point: MKMapPoint, center: MKMapPoint, scale: Double,
                            heading: CLLocationDirection, viewSize: CGSize,
                            cameraPoint: CGPoint? = nil) -> CGPoint {
        let origin = cameraPoint ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let offset = toScreen(dx: point.x - center.x, dy: point.y - center.y, heading: heading)
        return CGPoint(x: origin.x + offset.dx / scale, y: origin.y + offset.dy / scale)
    }

    /// The band less the margin, or the whole view when the band is too small to frame anything in.
    private static func innerBand(_ band: CGRect, viewSize: CGSize) -> CGRect {
        let usable = band.width >= 1 && band.height >= 1 ? band : CGRect(origin: .zero, size: viewSize)
        let inset = min(margin, usable.width / 4, usable.height / 4)
        return usable.insetBy(dx: inset, dy: inset)
    }

    /// The camera centre that puts `point` at `spot` in the view.
    private static func center(putting point: MKMapPoint, at spot: CGPoint, viewCenter: CGPoint,
                               scale: Double, heading: CLLocationDirection) -> MKMapPoint {
        let back = toMap(dx: (spot.x - viewCenter.x) * scale, dy: (spot.y - viewCenter.y) * scale, heading: heading)
        return MKMapPoint(x: point.x - back.dx, y: point.y - back.dy)
    }

    /// A map vector (map points: x east, y south) as the screen shows it: turned back by the heading.
    private static func toScreen(dx: Double, dy: Double, heading: CLLocationDirection) -> CGVector {
        let h = heading * .pi / 180
        return CGVector(dx: dx * cos(h) + dy * sin(h), dy: -dx * sin(h) + dy * cos(h))
    }

    private static func toMap(dx: Double, dy: Double, heading: CLLocationDirection) -> CGVector {
        let h = heading * .pi / 180
        return CGVector(dx: dx * cos(h) - dy * sin(h), dy: dx * sin(h) + dy * cos(h))
    }

    // MARK: - Closing

    /// The map as it was when the panel opened.
    struct SavedCamera: Equatable {
        var center: CLLocationCoordinate2D
        var span: MKCoordinateSpan
        var distance: CLLocationDistance
        var heading: CLLocationDirection
        var following: Bool

        static func == (a: SavedCamera, b: SavedCamera) -> Bool {
            a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude
                && a.span.latitudeDelta == b.span.latitudeDelta && a.span.longitudeDelta == b.span.longitudeDelta
                && a.distance == b.distance && a.heading == b.heading && a.following == b.following
        }
    }

    /// What the map goes back to when the panel closes. Following the aircraft: still following it,
    /// where it is now, at the zoom it had (in Track up, on the track now). Panned away: the very camera
    /// it had, centre, zoom and heading.
    static func restored(_ saved: SavedCamera, aircraft: CLLocationCoordinate2D?,
                         trackUpCourse: CLLocationDirection?) -> SavedCamera {
        guard saved.following, let aircraft else { return saved }
        var camera = saved
        camera.center = aircraft
        if let trackUpCourse { camera.heading = trackUpCourse }
        return camera
    }
}
