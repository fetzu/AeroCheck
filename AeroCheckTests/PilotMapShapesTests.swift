import MapKit
import MapLibre
import XCTest
@testable import AeroCheck

/// The map's lines and areas on MapLibre (6.8.0, PR 6): painted as the MapKit renderers say, grouped into style layers
/// by tier and paint, stacked as MapKit stacked them.
@MainActor
final class PilotMapShapesTests: XCTestCase {

    /// The track up to its last whole minute and the live end from there, sharing the cut point (6.10.0).
    func testTheTrackSplitsAtItsLastWholeMinute() {
        let t0 = Date(timeIntervalSinceReferenceDate: 60 * 1_000)
        let track = (0..<30).map { GPSPoint(latitude: 47, longitude: 7 + Double($0) / 1000, altitude: 500,
                                            timestamp: t0.addingTimeInterval(Double($0) * 5)) }
        // 29 × 5 s = 145 s: the last whole minute is t0 + 120 s, point 24.
        let (history, tail) = PilotMapShapes.splitTrack(track)
        XCTAssertEqual(history.count, 25)
        XCTAssertEqual(tail.first?.id, history.last?.id, "the line is whole")
        XCTAssertEqual(tail.last?.id, track.last?.id)
        // Three points later the history is the same, so the map isn't sent it again.
        let later = track + (30..<33).map { GPSPoint(latitude: 47, longitude: 7, altitude: 500,
                                                     timestamp: t0.addingTimeInterval(Double($0) * 5)) }
        XCTAssertEqual(PilotMapShapes.splitTrack(later).history.last?.id, history.last?.id)
        XCTAssertTrue(PilotMapShapes.splitTrack([]).history.isEmpty)
    }
    /// The track vector starts at the aircraft as drawn, its ticks moved with it (the author, 11 Nov: a hole between
    /// the aircraft and the line ahead, the glide drawing the aircraft a second's flight behind its latest fix); and
    /// the line to a diversion field starts there too.
    func testTheAircraftsLinesStartWhereItIsDrawn() {
        var main = [CLLocationCoordinate2D(latitude: 47, longitude: 7), CLLocationCoordinate2D(latitude: 47.1, longitude: 7)]
        var tick = [CLLocationCoordinate2D(latitude: 47.02, longitude: 6.999), CLLocationCoordinate2D(latitude: 47.02, longitude: 7.001)]
        let lines: [MKPolyline] = [TrackVectorCasingPolyline(coordinates: &main, count: 2), TrackVectorPolyline(coordinates: &main, count: 2),
                                   TrackVectorCasingPolyline(coordinates: &tick, count: 2), TrackVectorPolyline(coordinates: &tick, count: 2)]
        let drawn = CLLocationCoordinate2D(latitude: 46.9995, longitude: 7.0002)
        let moved = PilotMapShapes.vector(lines, from: drawn)
        XCTAssertEqual(moved.count, 4)
        XCTAssertTrue(moved[0] is TrackVectorCasingPolyline)
        XCTAssertFalse(moved[1] is TrackVectorCasingPolyline)
        XCTAssertEqual(moved[1].points()[0].coordinate.latitude, 46.9995, accuracy: 1e-7)
        XCTAssertEqual(moved[1].points()[0].coordinate.longitude, 7.0002, accuracy: 1e-7)
        XCTAssertEqual(moved[3].points()[1].coordinate.latitude, 47.0195, accuracy: 1e-7, "the ticks with it")
        XCTAssertEqual(moved[3].points()[1].coordinate.longitude, 7.0012, accuracy: 1e-7)
        XCTAssertTrue(PilotMapShapes.vector(lines, from: nil)[0] === lines[0], "on its fix: the same lines")
        XCTAssertTrue(PilotMapShapes.vector(lines, from: main[0])[0] === lines[0])
        XCTAssertTrue(PilotMapShapes.vector([], from: drawn).isEmpty)

        let field = CLLocationCoordinate2D(latitude: 47.3, longitude: 7.4)
        XCTAssertEqual(PilotMapShapes.diversionLine(from: drawn, to: field).count, 2)
        XCTAssertTrue(PilotMapShapes.diversionLine(from: nil, to: field).isEmpty)
        XCTAssertTrue(PilotMapShapes.diversionLine(from: drawn, to: nil).isEmpty, "not diverting: no line")
    }

    /// The track reaches the aircraft (the author, 11 Nov: a hole just behind it, filling again): a point every 5 s,
    /// so a last line from the last recorded point to the aircraft as drawn; gliding, the aircraft is drawn a moment
    /// behind its latest fix, so the line stops at the last point it has passed.
    func testTheTrackReachesTheAircraftAsDrawn() {
        let t0 = Date(timeIntervalSinceReferenceDate: 60 * 1_000)
        let points = (0..<4).map { GPSPoint(latitude: 47, longitude: 7 + Double($0) / 1000, altitude: 500,
                                            timestamp: t0.addingTimeInterval(Double($0) * 5)) }
        let tail = points[...]
        XCTAssertEqual(PilotMapShapes.passed(tail, at: t0.addingTimeInterval(11)).count, 3, "points 0, 1, 2 passed")
        XCTAssertEqual(PilotMapShapes.passed(tail, at: t0.addingTimeInterval(99)).count, 4)
        XCTAssertEqual(PilotMapShapes.passed(tail, at: t0.addingTimeInterval(-1)).count, 1, "the cut point always")
        XCTAssertTrue(PilotMapShapes.passed([], at: t0).isEmpty)

        let last = CLLocationCoordinate2D(latitude: 47, longitude: 7.002)
        let aircraft = CLLocationCoordinate2D(latitude: 47, longitude: 7.0027)
        XCTAssertEqual(PilotMapShapes.liveEnd(from: last, to: aircraft).count, 2)
        XCTAssertTrue(PilotMapShapes.liveEnd(from: last, to: last).isEmpty, "on its point: no line")
        XCTAssertTrue(PilotMapShapes.liveEnd(from: nil, to: aircraft).isEmpty)
        XCTAssertTrue(PilotMapShapes.liveEnd(from: last, to: nil).isEmpty)
    }

    private let traits = UITraitCollection(userInterfaceStyle: .light)

    private func line(_ coords: [CLLocationCoordinate2D]) -> MKPolyline {
        MKPolyline(coordinates: coords, count: coords.count)
    }

    private let a = CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03)
    private let b = CLLocationCoordinate2D(latitude: 47.50, longitude: 7.20)
    private let c = CLLocationCoordinate2D(latitude: 47.45, longitude: 7.40)

    // MARK: Paint

    func testPaintIsTheRenderersWithItsAlpha() throws {
        let renderer = MKPolygonRenderer(polygon: MKPolygon(coordinates: [a, b, c], count: 3))
        renderer.fillColor = UIColor.red.withAlphaComponent(0.5)
        renderer.strokeColor = UIColor.blue
        renderer.lineWidth = 1.5
        renderer.lineDashPattern = [8, 4]
        renderer.alpha = 0.5
        let paint = try XCTUnwrap(PilotMapShapes.Paint(renderer))
        XCTAssertEqual(paint.fill?.cgColor.alpha ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(paint.stroke?.cgColor.alpha ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(paint.width, 1.5)
        XCTAssertEqual(paint.dashInWidths, [8 / 1.5, 4 / 1.5], "MapLibre counts dashes in line widths")
        XCTAssertNil(PilotMapShapes.Paint(MKOverlayRenderer(overlay: line([a, b]))), "no path, nothing to paint")
    }

    func testColoursAsMapLibreReadsThem() {
        XCTAssertEqual(PilotMapShapes.css(UIColor(red: 1, green: 0, blue: 0.8, alpha: 1), traits: traits), "rgba(255,0,204,1.0)")
        XCTAssertEqual(PilotMapShapes.css(UIColor.black.withAlphaComponent(0.5), traits: traits), "rgba(0,0,0,0.5)")
        XCTAssertEqual(PilotMapShapes.css(UIColor.white, traits: traits), "rgba(255,255,255,1.0)", "a grey colour space too")
    }

    // MARK: Features and layers

    func testTheRouteIsPaintedAsOnMapKit() throws {
        let remaining = FlightPlanRoutePolyline(coordinates: [a, b], count: 2)
        let shape = PilotMapShapes.Shape(overlay: remaining, renderer: AeroMapView.lineRenderer(for: remaining, layerType: .icao),
                                         tier: 0)
        let (features, keys) = PilotMapShapes.features(for: [shape], group: .route, traits: traits)
        let feature = try XCTUnwrap(features.first)
        XCTAssertEqual(feature.attribute(forKey: "stroke") as? String, "rgba(255,0,204,1.0)")
        XCTAssertEqual(feature.attribute(forKey: "width") as? Double, 5)
        XCTAssertNil(feature.attribute(forKey: "fill"))
        XCTAssertEqual(keys.count, 1)
    }

    func testAnAreaGetsAFillAndAnEdge() throws {
        let polygon = AirspacePolygon(coordinates: [a, b, c], count: 3)
        polygon.mapKind = .controlled
        let renderer = MKPolygonRenderer(polygon: polygon)
        polygon.style(renderer, selected: false)
        let (features, keys) = PilotMapShapes.features(for: [.init(overlay: polygon, renderer: renderer, tier: 0)],
                                                       group: .airspace, traits: traits)
        let feature = try XCTUnwrap(features.first as? MLNPolygonFeature)
        XCTAssertNotNil(feature.attribute(forKey: "fill"))
        XCTAssertNotNil(feature.attribute(forKey: "stroke"))
        XCTAssertEqual(Set(keys.map(\.kind)), [.fill, .line(cap: .round, dash: [])])
    }

    func testAClassEAreaIsADashedEdgeWithNoWash() throws {
        let polygon = AirspacePolygon(coordinates: [a, b, c], count: 3)
        polygon.mapKind = .classE
        let renderer = MKPolygonRenderer(polygon: polygon)
        polygon.style(renderer, selected: false)
        let (features, keys) = PilotMapShapes.features(for: [.init(overlay: polygon, renderer: renderer, tier: 0)],
                                                       group: .airspace, traits: traits)
        XCTAssertNil(try XCTUnwrap(features.first).attribute(forKey: "fill"))
        XCTAssertEqual(Set(keys.map(\.kind)), [.line(cap: .round, dash: [8 / 2.2, 4 / 2.2])])
    }

    func testARestrictedAreaIsHatchedAndNeverWashed() throws {
        let polygon = AirspacePolygon(coordinates: [a, b, c], count: 3)
        polygon.mapKind = .restrictive
        let renderer = MKPolygonRenderer(polygon: polygon)
        polygon.style(renderer, selected: false)
        let shape = PilotMapShapes.Shape(overlay: polygon, renderer: renderer, tier: 0,
                                         hatch: polygon.hatchAlpha(selected: false))
        let (features, keys) = PilotMapShapes.features(for: [shape], group: .airspace, traits: traits)
        let feature = try XCTUnwrap(features.first)
        XCTAssertNil(feature.attribute(forKey: "fill"))
        XCTAssertEqual(feature.attribute(forKey: "hatch") as? Double, 0.9)
        XCTAssertEqual(Set(keys.map(\.kind)), [.hatch, .line(cap: .round, dash: [])])
    }

    func testTheTiersFadeAndNothingIsHidden() {
        let polygon = AirspacePolygon(coordinates: [a, b, c], count: 3)
        polygon.mapKind = .restrictive
        var edges: [CGFloat] = []
        for tier in AirspaceMapTier.allCases {
            polygon.tier = tier
            let renderer = MKPolygonRenderer(polygon: polygon)
            polygon.style(renderer, selected: false)
            let alpha = renderer.strokeColor?.cgColor.alpha ?? 0
            XCTAssertGreaterThan(alpha, 0, "a faint area stays drawn: \(tier)")
            edges.append(alpha)
        }
        XCTAssertEqual(edges, edges.sorted())
        polygon.tier = .far
        XCTAssertEqual(polygon.hatchAlpha(selected: false), 0)
        XCTAssertEqual(polygon.hatchAlpha(selected: true), 0.9, "a selected area shows whatever its tier")
    }

    func testAnAirspaceNeverWearsAColourOfTheContract() {
        // Red, amber, magenta and cyan mean a warning, a caution, the route and a control in flight (a1 A).
        let contract: [UIColor] = [.init(red: 1, green: 0, blue: 0, alpha: 1), .init(red: 1, green: 0.75, blue: 0, alpha: 1),
                                   .init(red: 1, green: 0, blue: 0.8, alpha: 1), .init(red: 0, green: 0.75, blue: 0.9, alpha: 1)]
        func hue(_ color: UIColor) -> CGFloat {
            var h: CGFloat = 0; color.getHue(&h, saturation: nil, brightness: nil, alpha: nil); return h * 360
        }
        for kind in AirspaceMapKind.allCases {
            let c = kind.color
            let color = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
            var saturation: CGFloat = 0
            color.getHue(nil, saturation: &saturation, brightness: nil, alpha: nil)
            guard saturation > 0.45 else { continue }  // Charcoal and slate have next to no hue
            for wanted in contract {
                let apart = abs(hue(color) - hue(wanted))
                XCTAssertGreaterThan(min(apart, 360 - apart), 15, "\(kind)")
            }
        }
    }

    func testEveryAirspaceFindsItsKind() {
        func kind(_ type: AirspaceTypeCategory, _ cls: Int? = nil) -> AirspaceMapKind {
            let limit = AltitudeLimit(value: 0, unit: 1, referenceDatum: 0)
            return Airspace(id: "a", name: "A", type: type.rawValue, icaoClass: cls, country: "CH", upperCeiling: limit,
                            lowerCeiling: limit, geometry: AirspaceGeometry(type: "Polygon", coordinates: []), activity: nil,
                            frequencies: nil).mapKind
        }
        XCTAssertEqual(kind(.restricted), .restrictive)
        XCTAssertEqual(kind(.danger, 8), .restrictive)
        XCTAssertEqual(kind(.prohibited), .restrictive)
        XCTAssertEqual(kind(.tma, 3), .controlled)
        XCTAssertEqual(kind(.tma, 4), .classE)
        XCTAssertEqual(kind(.other, 4), .classE)
        XCTAssertEqual(kind(.ctr), .controlled)
        XCTAssertEqual(kind(.tmz), .zone)
        XCTAssertEqual(kind(.rmz), .zone)
        XCTAssertEqual(kind(.gliderSector), .glider)
        XCTAssertEqual(kind(.other, 6), .neutral)
    }

    func testAnInvisibleShapeMakesNoFeature() {
        let renderer = MKPolylineRenderer(polyline: line([a, b]))
        renderer.strokeColor = .clear
        renderer.lineWidth = 3
        let (features, keys) = PilotMapShapes.features(for: [.init(overlay: line([a, b]), renderer: renderer, tier: 0)],
                                                       group: .track, traits: traits)
        XCTAssertTrue(features.isEmpty)
        XCTAssertTrue(keys.isEmpty)
    }

    func testGeometries() throws {
        XCTAssertTrue(PilotMapShapes.feature(for: line([a, b])) is MLNPolylineFeature)
        XCTAssertNil(PilotMapShapes.feature(for: line([a])), "a line of one point")
        let multi = MKMultiPolyline([line([a, b]), line([b, c])])
        let feature = try XCTUnwrap(PilotMapShapes.feature(for: multi) as? MLNMultiPolylineFeature)
        XCTAssertEqual(feature.polylines.count, 2)
        let hole = MKPolygon(coordinates: [a, b, c], count: 3)
        let outer = MKPolygon(coordinates: [a, b, c], count: 3, interiorPolygons: [hole])
        let polygon = try XCTUnwrap(PilotMapShapes.feature(for: outer) as? MLNPolygonFeature)
        XCTAssertEqual(polygon.interiorPolygons?.count, 1)
    }

    // MARK: Stacking

    func testLayersStackAsMapKitStackedThem() {
        typealias Key = PilotMapShapes.LayerKey
        let keys: [Key] = [
            Key(group: .route, tier: 1, kind: .line(cap: .round, dash: [])),
            Key(group: .airspace, tier: 1, kind: .line(cap: .round, dash: [])),
            Key(group: .airspace, tier: 0, kind: .line(cap: .round, dash: [])),
            Key(group: .airspace, tier: 0, kind: .fill),
            Key(group: .airspace, tier: 0, kind: .hatch),
            Key(group: .route, tier: 0, kind: .line(cap: .round, dash: [])),
        ]
        XCTAssertEqual(keys.sorted().map(\.id), [
            "aero.airspace.0.fill", "aero.airspace.0.hatch", "aero.airspace.0.line.1", "aero.airspace.1.line.1",
            "aero.route.0.line.1", "aero.route.1.line.1",
        ])
    }

    func testTheProceduresKeepTheirTiers() throws {
        // A circuit's casing under its core, as on MapKit: two tiers, the casing first.
        let casing = VFRCircuitOverlay(coordinates: [a, b, c], count: 3)
        casing.stroke = .casing
        let core = VFRCircuitOverlay(coordinates: [a, b, c], count: 3)
        let shapes = [core, casing].map {
            PilotMapShapes.Shape(overlay: $0, renderer: VFRMapLayer.renderer(for: $0, palette: .day),
                                 tier: VFRMapLayer.tier(of: $0) ?? 0)
        }
        let (_, keys) = PilotMapShapes.features(for: shapes, group: .procedures, traits: traits)
        let ordered = keys.sorted()
        XCTAssertEqual(ordered.count, 2)
        XCTAssertLessThan(try XCTUnwrap(ordered.first?.tier), try XCTUnwrap(ordered.last?.tier))
    }

    // MARK: Builders shared with MapKit

    func testTheRouteSplitsWhereTheFlightIs() {
        var plan = FlightPlan(name: "Test", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: a), FlightPlanWaypoint(name: "B", coordinate: b),
            FlightPlanWaypoint(name: "C", coordinate: c),
        ])
        XCTAssertEqual(AeroMapView.routePolylines(for: plan).map(\.isCompletedSegment), [false])
        plan.currentWaypointIndex = 1
        let lines = AeroMapView.routePolylines(for: plan)
        XCTAssertEqual(lines.map(\.isCompletedSegment), [true, false])
        XCTAssertEqual(lines.map(\.pointCount), [2, 2])
    }

    func testThePlannedRoutesLines() {
        var route = PlannedRoute()
        route.waypoints = [FlightPlanWaypoint(name: "A", coordinate: a), FlightPlanWaypoint(name: "B", coordinate: b)]
        XCTAssertEqual(PlannedRouteLayer.lines(for: route).map { String(describing: type(of: $0)) },
                       ["RouteCasingPolyline", "RouteLinePolyline"])
        route.selectedLeg = 0
        XCTAssertTrue(PlannedRouteLayer.lines(for: route).first is SelectedLegPolyline, "the halo under the route")
        route.waypoints.removeLast()
        XCTAssertTrue(PlannedRouteLayer.lines(for: route).isEmpty)
    }

    func testTheOwnshipImage() throws {
        let image = try XCTUnwrap(AeroMapView.ownshipImage)
        XCTAssertGreaterThan(image.size.width, 20)
    }
}
