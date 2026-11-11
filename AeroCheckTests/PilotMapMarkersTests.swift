import MapKit
import MapLibre
import XCTest
@testable import AeroCheck

/// The map's markers on MapLibre (6.8.0, PR 7): which markers a map shows, under keys that change only when what
/// they draw does; their images, taps and callouts as the MapKit view has them.
@MainActor
final class PilotMapMarkersTests: XCTestCase {
    private let lszq = CLLocationCoordinate2D(latitude: 47.392408, longitude: 7.028956)
    private let lspd = CLLocationCoordinate2D(latitude: 47.6125, longitude: 7.3725)

    private func airport(_ ident: String, _ at: CLLocationCoordinate2D) -> Airport {
        Airport(id: abs(ident.hashValue % 100_000), ident: ident, type: .smallAirport, name: ident,
                latitude: at.latitude, longitude: at.longitude, elevation: 1500, continent: "EU",
                isoCountry: "CH", isoRegion: "CH-JU", municipality: nil, scheduledService: false,
                gpsCode: nil, iataCode: nil, localCode: nil)
    }

    private func map(airports: [Airport] = [], plan: FlightPlan? = nil, planned: PlannedRoute = PlannedRoute(),
                     features: MapFeatures = .navigation) -> AeroMapView {
        AeroMapView(layerType: .icao, mapState: SharedMapState(), currentLocation: nil, gpsTrack: [],
                    isFollowingAircraft: .constant(true), forceICAOLayer: false, activeFlightPlan: plan,
                    visibleAirports: airports, features: features, plannedRoute: planned)
    }

    private func keys(_ map: AeroMapView) -> [String] {
        PilotMapMarkers.wanted(map: map, content: map.shownProcedures, plan: map.shownPlan,
                               planned: map.shownPlannedRoute, revision: 0).map(\.key)
    }

    // MARK: Which markers

    func testAerodromesAsTheSurfaceShowsThem() {
        let fields = [airport("LSZQ", lszq), airport("LSPD", lspd)]
        XCTAssertEqual(keys(map(airports: fields)).filter { $0.hasPrefix("apt|") }.count, 2)
        XCTAssertTrue(keys(map(airports: fields, features: .chartOnly)).isEmpty, "a surface without aerodromes draws none")
    }

    func testAWaypointsKeyFollowsItsState() {
        var plan = FlightPlan(name: "T", waypoints: [FlightPlanWaypoint(name: "LSZQ", coordinate: lszq),
                                                    FlightPlanWaypoint(name: "LSPD", coordinate: lspd)])
        let before = keys(map(plan: plan)).filter { $0.hasPrefix("wpt|") }
        XCTAssertEqual(before.count, 2)
        plan.currentWaypointIndex = 1
        let after = keys(map(plan: plan)).filter { $0.hasPrefix("wpt|") }
        XCTAssertEqual(Set(before).intersection(after), [], "a passed waypoint is a new marker: its disc changes")
    }

    func testThePlannedRoutesPins() {
        var route = PlannedRoute()
        route.waypoints = [FlightPlanWaypoint(name: "A", coordinate: lszq), FlightPlanWaypoint(name: "B", coordinate: lspd)]
        let plain = keys(map(planned: route, features: .builder)).filter { $0.hasPrefix("pin|") }
        XCTAssertEqual(plain.count, 2)
        route.conflictLegs = [0]
        let conflict = keys(map(planned: route, features: .builder)).filter { $0.hasPrefix("pin|") }
        XCTAssertNotEqual(plain.sorted(), conflict.sorted(), "an amber pin is redrawn")
    }

    func testSameInputsSameKeys() {
        let fields = [airport("LSZQ", lszq)]
        XCTAssertEqual(keys(map(airports: fields)), keys(map(airports: fields)))
    }

    // MARK: Taps and images

    func testWhatATapOpens() {
        XCTAssertTrue(PilotMapMarkers.hasCallout(AirportAnnotation(airport: airport("LSZQ", lszq))))
        XCTAssertFalse(PilotMapMarkers.hasCallout(FlightPlanWaypointAnnotation(coordinate: lszq, name: "LSZQ", index: 0,
                                                                              currentIndex: 0)),
                       "a waypoint's tap is its time over")
        XCTAssertFalse(PilotMapMarkers.hasCallout(VFRApproachAnnotation(kind: .parachute, field: "LSZQ", coordinate: lszq)))
    }

    /// Marker C (the author's pick, 30 Oct 2026): a numbered disc centred on the waypoint, amber on a conflict.
    func testThePinIsADiscWithItsNumber() {
        let pin = PilotMapMarkers.pinImage(number: 3, conflict: false)
        XCTAssertEqual(pin.size, CGSize(width: 38, height: 38), "square: centred on the point, no tip")
        XCTAssertNotEqual(pin.pngData(), PilotMapMarkers.pinImage(number: 3, conflict: true).pngData())
    }

    /// While dragged, the disc rides above the finger on a stem; its dot lands on the coordinate.
    func testTheDraggedPinIsLiftedWithItsDotOnThePoint() {
        let lifted = PilotMapMarkers.liftedPinImage(label: "2")
        XCTAssertEqual(lifted.image.size, CGSize(width: 48, height: 100))
        XCTAssertEqual(lifted.dotOffset, CGVector(dx: 0, dy: -42), "the dot, 92 pt down a 100 pt image, on the point")
    }

    func testAMarkerTakesATapOverItsImage() throws {
        let view = PilotMarkerView(reuseIdentifier: nil)
        view.show(AeroMarkerImages.navaid)
        XCTAssertGreaterThanOrEqual(view.bounds.width, 30, "a finger's width at least")
        XCTAssertTrue(view.point(inside: CGPoint(x: view.bounds.midX, y: view.bounds.midY), with: nil))
    }

    func testOnlyAPillTakesATap() throws {
        let view = PilotMarkerView(reuseIdentifier: nil)
        let pill = VFRProcedureLabelImage.pillImage(text: "2900 ft", palette: .day)
        view.showPill(pill, angle: .pi / 4, offset: .zero, duplicate: false)
        XCTAssertTrue(view.point(inside: CGPoint(x: view.bounds.midX, y: view.bounds.midY), with: nil))
        XCTAssertFalse(view.point(inside: CGPoint(x: 1, y: 1), with: nil), "a turned pill's box corner is the chart")
        view.showPill(pill, angle: 0, offset: .zero, duplicate: true)
        XCTAssertFalse(view.point(inside: CGPoint(x: view.bounds.midX, y: view.bounds.midY), with: nil),
                       "a duplicate isn't drawn and takes no tap")
    }

    /// The pill's view hugs it beside its line, a 44 pt target at least whatever the device's pill height (27 pt on
    /// the iPhone), and only the pill takes a tap. (6.6.0, on MapLibre since 6.8.0)
    func testAPillIsAFullTargetBesideItsLine() {
        let view = PilotMarkerView(reuseIdentifier: nil)
        let text = "2000 ft"
        let pill = VFRProcedureLabelImage.pillImage(text: text, palette: .day)
        XCTAssertEqual(pill.size, VFRProcedureLabelImage.pillBox(text: text))
        for (angle, above) in [(CGFloat(0), true), (.pi / 6, false), (-.pi / 3, true)] {
            let offset = VFRPill.offset(size: pill.size, level: 1, gap: 6, angle: angle, above: above)
            view.showPill(pill, angle: angle, offset: offset, duplicate: false)
            XCTAssertEqual(view.centerOffset, CGVector(dx: offset.x, dy: offset.y))
            XCTAssertEqual(hypot(offset.x, offset.y), 6 + pill.size.height + 6 + pill.size.height / 2, accuracy: 0.01,
                           "a pill further out than the one beside the line")
            XCTAssertGreaterThanOrEqual(min(view.bounds.width, view.bounds.height), VFRPillTap.minimumTarget)
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            XCTAssertTrue(view.point(inside: centre, with: nil), "\(angle)")
            let edge = CGPoint(x: centre.x - 21.9 * sin(angle), y: centre.y + 21.9 * cos(angle))
            XCTAssertTrue(view.point(inside: edge, with: nil), "22 pt across the pill, \(angle)")
            if angle != 0 {
                XCTAssertFalse(view.point(inside: CGPoint(x: 1, y: 1), with: nil), "a corner of the box: the chart, \(angle)")
            }
        }
    }

    func testABubbleFitsItsText() {
        let bubble = PilotMarkerBubble(title: "WITZWIL", subtitle: "LSZQ · on request", detail: nil, add: {})
        XCTAssertGreaterThanOrEqual(bubble.bounds.width, 120)
        XCTAssertLessThanOrEqual(bubble.bounds.width, 340)
        XCTAssertGreaterThan(bubble.bounds.height, PilotMarkerBubble.tailHeight + 20)
    }

    /// The track vector is a view on the aircraft's place (the review of 11 Nov, finding 10): painted as the map's
    /// line renderer says, its lines cut to what the map shows (five minutes of flight are thousands of points long
    /// zoomed in).
    func testTheTrackVectorIsAViewCutToTheMap() {
        typealias M = PilotMapMarkers
        let rect = CGRect(x: -100, y: -200, width: 200, height: 400)
        // Straight up from the aircraft, far past the top: kept from the aircraft to the edge.
        let up = M.clipped(.zero, CGPoint(x: 0, y: -15_000), to: rect)
        XCTAssertEqual(up?.0, .zero)
        XCTAssertEqual(up?.1, CGPoint(x: 0, y: -200))
        // A mark across the line, wholly inside: as it is.
        let mark = M.clipped(CGPoint(x: -20, y: -50), CGPoint(x: 20, y: -50), to: rect)
        XCTAssertEqual(mark?.0, CGPoint(x: -20, y: -50))
        XCTAssertEqual(mark?.1, CGPoint(x: 20, y: -50))
        // The five-minute mark, off the map: nothing.
        XCTAssertNil(M.clipped(CGPoint(x: -20, y: -9_000), CGPoint(x: 20, y: -9_000), to: rect))
        // The aircraft off the map to the left, the vector crossing it: the part inside.
        let across = M.clipped(CGPoint(x: -500, y: 0), CGPoint(x: 500, y: 100), to: rect)
        XCTAssertEqual(across?.0.x ?? 0, -100, accuracy: 1e-9)
        XCTAssertEqual(across?.1.x ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(across?.0.y ?? 0, 40, accuracy: 1e-9)
        XCTAssertNil(M.clipped(CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 50), to: rect), "beside the map")
        XCTAssertNotNil(M.clipped(CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), to: rect), "a point inside stays")

        let path = M.vectorPath([[.zero, CGPoint(x: 0, y: -15_000)], [CGPoint(x: -20, y: -9_000), CGPoint(x: 20, y: -9_000)]],
                                within: rect)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: -200, width: 0, height: 200), "only what shows")
        XCTAssertTrue(M.vectorPath([], within: rect).isEmpty)

        var main = [CLLocationCoordinate2D(latitude: 47, longitude: 7), CLLocationCoordinate2D(latitude: 47.1, longitude: 7)]
        let lines: [MKPolyline] = [TrackVectorCasingPolyline(coordinates: &main, count: 2), TrackVectorPolyline(coordinates: &main, count: 2)]
        let casing = M.vectorPaint(lines, casing: true, layerType: .icao)
        let core = M.vectorPaint(lines, casing: false, layerType: .icao)
        XCTAssertEqual(casing?.width, 6)
        XCTAssertEqual(core?.width, 3)
        XCTAssertEqual(casing?.stroke?.cgColor.alpha ?? 0, 0.5, accuracy: 1e-6, "the dark edge, half see-through")
        XCTAssertEqual(core?.cap, .round)
        XCTAssertNil(M.vectorPaint([], casing: true, layerType: .icao))
    }

    func testTheAircraftIsNotAShapeAnyMore() {
        XCTAssertFalse(PilotMapShapes.Group.allCases.map(\.sourceID).contains("aero.aircraft"),
                       "the aircraft is a marker, above the others")
    }
}
