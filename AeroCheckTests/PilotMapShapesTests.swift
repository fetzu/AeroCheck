import MapKit
import MapLibre
import XCTest
@testable import AeroCheck

/// The map's lines and areas on MapLibre (6.8.0, PR 6): painted as the MapKit renderers say, grouped into style layers
/// by tier and paint, stacked as MapKit stacked them.
@MainActor
final class PilotMapShapesTests: XCTestCase {
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
        polygon.overlayColor = (0.2, 0.4, 0.8)
        polygon.isDashed = true
        let renderer = MKPolygonRenderer(polygon: polygon)
        polygon.style(renderer, selected: false)
        let (features, keys) = PilotMapShapes.features(for: [.init(overlay: polygon, renderer: renderer, tier: 0)],
                                                       group: .airspace, traits: traits)
        let feature = try XCTUnwrap(features.first as? MLNPolygonFeature)
        XCTAssertNotNil(feature.attribute(forKey: "fill"))
        XCTAssertNotNil(feature.attribute(forKey: "stroke"))
        XCTAssertEqual(Set(keys.map(\.kind)), [.fill, .line(cap: .round, dash: [8 / 1.5, 4 / 1.5])])
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
            Key(group: .aircraft, tier: 0, kind: .symbol),
            Key(group: .route, tier: 1, kind: .line(cap: .round, dash: [])),
            Key(group: .airspace, tier: 1, kind: .line(cap: .round, dash: [])),
            Key(group: .airspace, tier: 0, kind: .line(cap: .round, dash: [])),
            Key(group: .airspace, tier: 0, kind: .fill),
            Key(group: .route, tier: 0, kind: .line(cap: .round, dash: [])),
        ]
        XCTAssertEqual(keys.sorted().map(\.id), [
            "aero.airspace.0.fill", "aero.airspace.0.line.1", "aero.airspace.1.line.1",
            "aero.route.0.line.1", "aero.route.1.line.1", "aero.aircraft.0.symbol",
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
