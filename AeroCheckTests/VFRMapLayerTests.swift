import XCTest
import MapKit
import SwiftUI
@testable import AeroCheck

/// The aerodrome procedures on the maps (6.2.0): which procedures the switches show, the density gates
/// and the cap, where the labels go and which way the arrows point, the overlay classes and their
/// renderers on all three maps (never the generic `MKPolyline` branch), the diff that keeps them under
/// the route and survives the route's redraws, the callout, and the error report to open flightmaps.
/// Fixtures are cut from the real AIRAC 2610 Swiss file (© open flightmaps association).
@MainActor
final class VFRMapLayerTests: XCTestCase {

    // MARK: - Fixtures

    /// LSZQ's circuit and east arrival with its sector, a heavy circuit (LSGR), a glider circuit (LSZB),
    /// a glider-and-UL circuit, LSZH's helicopter arrival, a departure, a circuit without altitude.
    private func procedures() throws -> [VFRProcedure] {
        let json = """
        { "v": 1, "region": "LSAS", "country": "CH", "airac": "2610", "validFrom": "2026-10-01", "validTo": "2026-10-29",
          "procedures": [
            {"id": "f2fbd4ca-1edb-354d-414d-28863037c1ea", "ad": "LSZQ", "kind": "circuit", "name": "TC", "use": "fw", "cat": null, "alt": 2900,
             "line": [[7.03373, 47.39356], [7.05466, 47.39851], [7.05579, 47.4001], [7.04636, 47.41809], [7.044, 47.41884], [6.98485, 47.40447], [6.98375, 47.40284], [6.99369, 47.38507], [6.99602, 47.38434], [7.02427, 47.39125]]},
            {"id": "b14a1c24-a583-8fc1-252c-8324d6d5b6f8", "ad": "LSZQ", "kind": "arr", "name": "ARR SECTOR EAST", "use": "fw", "cat": null,
             "dir": "E", "offCircuit": [0, 2],
             "line": [[7.10158, 47.38718], [7.07828, 47.39336], [7.05721, 47.39871], [7.05612, 47.39946], [7.04636, 47.41809]],
             "areas": [{"kind": "corridor", "poly": [[7.10449, 47.39655], [7.07946, 47.39518], [7.07946, 47.39206], [7.09685, 47.38044]],
                        "label": [7.09321, 47.39044]}]},
            {"id": "fe731546-989c-258b-218b-dba8b8aa3ff4", "ad": "LSGR", "kind": "circuit", "name": "TC MULTI", "use": "fw", "cat": "heavy", "alt": 3500,
             "line": [[7.68155, 46.61693], [7.69123, 46.65887], [7.67561, 46.65771], [7.65353, 46.60322], [7.67584, 46.61202]]},
            {"id": "f4efc4c8-2db7-5a53-e5a8-0c5663e38b10", "ad": "LSZB", "kind": "circuit", "name": "TFC GLIDER 14R/32L", "use": "fw", "cat": "glider",
             "line": [[7.5, 46.90971], [7.50953, 46.90084], [7.50167, 46.89622], [7.47911, 46.91448], [7.49447, 46.9142]]},
            {"id": "98e5878d-b6af-a8b5-77e7-b806f639db63", "ad": "LSZB", "kind": "circuit", "name": "UL+GLIDER", "use": "fw", "cat": "glider+ul", "alt": 2000,
             "line": [[7.50, 46.91], [7.51, 46.90], [7.49, 46.90]]},
            {"id": "557a727b-340a-606f-81e2-1624fc612d7c", "ad": "LSZH", "kind": "arr", "name": "ECHO (REGA)", "use": "heli", "cat": "heli",
             "line": [[8.79, 47.53194], [8.70191, 47.52419], [8.63683, 47.50422], [8.57094, 47.45781]]},
            {"id": "22e2c2f1-f1a8-9e5c-df70-f93f7c7dad4e", "ad": "LSGC", "kind": "dep", "name": "DEP 06", "use": "fw", "cat": null, "approx": true,
             "line": [[6.79, 47.08], [6.80, 47.09], [6.82, 47.10]]},
            {"id": "056601d3-f3ea-67f6-534c-098907b797d6", "ad": "LSGC", "kind": "circuit", "name": "", "use": "fw", "cat": null,
             "line": [[6.79802, 47.08639], [6.81304, 47.09377], [6.82779, 47.08222], [6.789, 47.06145]]}
          ] }
        """
        return try JSONDecoder().decode(OFMRegionFile.self, from: Data(json.utf8)).procedures
    }

    private func procedure(named name: String) throws -> VFRProcedure {
        try XCTUnwrap(procedures().first { $0.name == name })
    }

    private func item(_ procedure: VFRProcedure, arrow: VFRArrow = .atEnd) -> VFRMapItem {
        VFRMapItem(procedure: procedure, arrow: procedure.kind == .circuit ? .none : arrow,
                   labelText: VFRMapItem.labelText(for: procedure),
                   labelAnchor: procedure.kind == .circuit ? VFRLabelPlacement.circuitAnchor(procedure.line)
                        : VFRLabelPlacement.midLine(procedure.line),
                   country: "CH", region: "LSAS", airac: "2610")
    }

    /// A region `spanNM` across (its shorter side) around LSZQ.
    private func region(spanNM: Double, lat: Double = 47.4, lon: Double = 7.03) -> MKCoordinateRegion {
        let cosLat = cos(lat * .pi / 180)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                  span: MKCoordinateSpan(latitudeDelta: spanNM / 60 * 1.4,
                                                         longitudeDelta: spanNM / (60 * cosLat)))
    }

    private let everything = VFRLayerSelection(circuits: true, routes: true, nonPowered: true)

    // MARK: - Which procedures

    func testTheSwitchesSelectByKindAndCategory() throws {
        let all = try procedures()
        func shown(_ selection: VFRLayerSelection) -> [String] { all.filter(selection.includes).map(\.ofmId) }
        let names = Dictionary(uniqueKeysWithValues: all.map { ($0.ofmId, $0.name) })

        let circuits = shown(VFRLayerSelection(circuits: true, routes: false, nonPowered: false)).compactMap { names[$0] }
        XCTAssertEqual(circuits, ["TC", "TC MULTI", ""], "powered circuits, the heavy one too, not the glider ones")

        let routes = shown(VFRLayerSelection(circuits: false, routes: true, nonPowered: false)).compactMap { names[$0] }
        XCTAssertEqual(routes, ["ARR SECTOR EAST", "DEP 06"], "no helicopter route without the third switch")

        let nonPowered = shown(VFRLayerSelection(circuits: false, routes: false, nonPowered: true)).compactMap { names[$0] }
        XCTAssertEqual(nonPowered, ["TFC GLIDER 14R/32L", "UL+GLIDER"], "the third switch works on its own")

        let routesAndHeli = shown(VFRLayerSelection(circuits: false, routes: true, nonPowered: true)).compactMap { names[$0] }
        XCTAssertEqual(routesAndHeli, ["ARR SECTOR EAST", "TFC GLIDER 14R/32L", "UL+GLIDER", "ECHO (REGA)", "DEP 06"])

        XCTAssertTrue(shown(VFRLayerSelection(circuits: false, routes: false, nonPowered: false)).isEmpty)
        XCTAssertEqual(shown(everything).count, all.count)
    }

    func testTheSettingsMakeTheSelection() {
        var settings = AppSettings()
        XCTAssertFalse(VFRLayerSelection(settings: settings).isAnyOn, "off by default")
        settings.showVFRRoutesOnMap = true
        XCTAssertEqual(VFRLayerSelection(settings: settings), VFRLayerSelection(circuits: false, routes: true, nonPowered: false))
    }

    // MARK: - Density

    func testTheDensityGatesAndTheCap() throws {
        let all = try procedures()
        XCTAssertEqual(VFRMapDensity.spanNM(of: region(spanNM: 10)), 10, accuracy: 0.001)

        let wide = VFRMapContent.make(candidates: all, region: region(spanNM: 41), selection: everything, palette: .day)
        XCTAssertTrue(wide.items.isEmpty, "nothing past 40 NM across")

        let mid = VFRMapContent.make(candidates: all, region: region(spanNM: 30), selection: everything, palette: .day)
        XCTAssertEqual(mid.items.count, all.count)
        XCTAssertFalse(mid.showsLabels, "no labels past 20 NM")

        let close = VFRMapContent.make(candidates: all, region: region(spanNM: 20), selection: everything, palette: .day)
        XCTAssertTrue(close.showsLabels)

        let off = VFRMapContent.make(candidates: all, region: region(spanNM: 5),
                                     selection: VFRLayerSelection(circuits: false, routes: false, nonPowered: false), palette: .day)
        XCTAssertTrue(off.items.isEmpty)

        // At most 80, the destination's first, then the departure's, then the nearest.
        let base = try procedure(named: "TC")
        let many = (0..<120).map { index -> VFRProcedure in
            let offset = Double(index) * 0.001
            return try! circuit(id: "x\(index)", aerodrome: index == 119 ? "LSGC" : "LSZQ",
                                around: (lat: 47.4 + offset, lon: 7.03 + offset))
        } + [base]
        let content = VFRMapContent.make(candidates: many, region: region(spanNM: 10), selection: everything,
                                         palette: .day, firstAerodromes: ["LSGC", "LSZQ"])
        XCTAssertEqual(content.items.count, VFRMapDensity.procedureLimit)
        XCTAssertEqual(content.items.first?.procedure.aerodrome, "LSGC", "the destination first")
        XCTAssertEqual(content.items[1].procedure.ofmId, "x0", "then the departure's, nearest first")
        XCTAssertFalse(content.items.contains { $0.procedure.ofmId == "x118" }, "the farthest are left out")
    }

    func testThePlansEndsComeFirst() {
        var plan = FlightPlan(name: "LSZQ-LSGC")
        plan.waypoints = [
            FlightPlanWaypoint(name: "LSZQ", coordinate: CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03)),
            FlightPlanWaypoint(name: "CHABREY", coordinate: CLLocationCoordinate2D(latitude: 46.93, longitude: 7.0)),
            FlightPlanWaypoint(name: "Les Eplatures", coordinate: CLLocationCoordinate2D(latitude: 47.08, longitude: 6.79)),
        ]
        plan.waypoints[2].pointKind = .aerodrome
        plan.waypoints[2].sourceId = "lsgc"
        XCTAssertEqual(VFRMapDensity.endpointAerodromes(of: plan), ["LSGC", "LSZQ"])
        XCTAssertEqual(VFRMapDensity.endpointAerodromes(of: nil), [])
    }

    private func circuit(id: String, aerodrome: String, around center: (lat: Double, lon: Double)) throws -> VFRProcedure {
        let json = """
        {"id": "\(id)", "ad": "\(aerodrome)", "kind": "circuit", "name": "TC", "cat": null, "alt": 3000,
         "line": [[\(center.lon), \(center.lat)], [\(center.lon + 0.01), \(center.lat)], [\(center.lon + 0.01), \(center.lat + 0.01)]]}
        """
        return try JSONDecoder().decode(VFRProcedure.self, from: Data(json.utf8))
    }

    // MARK: - Labels and arrows

    func testTheLabelsGoOnTheDownwindAndMidLine() throws {
        let circuit = try procedure(named: "TC")
        // The vertex farthest from the line's start (the runway): the downwind's far end at LSZQ.
        XCTAssertEqual(VFRLabelPlacement.circuitAnchor(circuit.line), VFRCoordinate(latitude: 47.40284, longitude: 6.98375))
        XCTAssertEqual(VFRMapItem.labelText(for: circuit), "2900 ft")
        XCTAssertEqual(VFRMapItem.labelText(for: try procedure(named: "")), L10n.VFRMap.altitudeSeeChart)
        XCTAssertEqual(L10n.VFRMap.altitudeSeeChart, "Alt: see chart")

        let line = [VFRCoordinate(latitude: 47, longitude: 7), VFRCoordinate(latitude: 47.1, longitude: 7)]
        let mid = VFRLabelPlacement.midLine(line)
        XCTAssertEqual(mid.latitude, 47.05, accuracy: 1e-9)
        XCTAssertEqual(mid.longitude, 7, accuracy: 1e-9)
        // Halfway along the length, not at the middle vertex.
        let bent = line + [VFRCoordinate(latitude: 47.1, longitude: 7.01)]
        XCTAssertEqual(VFRLabelPlacement.midLine(bent).latitude, 47.0 + (0.1 + 0.01 * cos(47.1 * .pi / 180)) / 2, accuracy: 1e-4)

        let arrival = try procedure(named: "ARR SECTOR EAST")
        XCTAssertEqual(VFRMapItem.labelText(for: arrival), "ARR SECTOR EAST")
    }

    func testTheArrowPointsTowardTheFieldOnArrivalAndAwayOnDeparture() throws {
        let lszq = CLLocationCoordinate2D(latitude: 47.3925, longitude: 7.0286)
        let arrival = try procedure(named: "ARR SECTOR EAST")
        XCTAssertEqual(VFRArrow.arrow(for: arrival, field: lszq), .atEnd, "the line ends at the field")
        XCTAssertEqual(VFRArrow.arrow(for: arrival, field: CLLocationCoordinate2D(latitude: 47.387, longitude: 7.102)),
                       .atStart, "drawn the other way, the arrow is at its start")

        let departure = try procedure(named: "DEP 06")
        let lsgc = CLLocationCoordinate2D(latitude: 47.0839, longitude: 6.7928)
        XCTAssertEqual(VFRArrow.arrow(for: departure, field: lsgc), .atEnd, "from the field outward")
        XCTAssertEqual(VFRArrow.arrow(for: departure, field: CLLocationCoordinate2D(latitude: 47.10, longitude: 6.82)),
                       .atStart, "a departure drawn into the field gets its arrow at the far end")
        XCTAssertEqual(VFRArrow.arrow(for: departure, field: nil), .atEnd, "without the field, the line's direction")
        XCTAssertEqual(VFRArrow.arrow(for: try procedure(named: "TC"), field: lszq), .none)
    }

    // MARK: - Overlays and renderers

    private let tenMetersAPoint = VFRMapLayer.Zoom(metersPerPoint: 10)

    func testEachProcedureHasItsOwnOverlayClasses() throws {
        // A solid circuit: two overlays, bottom to top, the casing then the core.
        let circuits = VFRMapLayer.overlays(for: item(try procedure(named: "TC"))).compactMap { $0 as? VFRCircuitOverlay }
        XCTAssertEqual(circuits.map(\.stroke), [.casing, .core])
        XCTAssertEqual(circuits.first?.procedureId, "CH:circuit:f2fbd4ca-1edb-354d-414d-28863037c1ea")
        XCTAssertEqual(circuits.first?.pointCount, 10)
        XCTAssertTrue(VFRMapLayer.scaledOverlays(for: item(try procedure(named: "TC")), zoom: tenMetersAPoint).isEmpty)

        // An arrival with its sector: the sector's fill and the solid line (casing, core) are fixed; the
        // sector's outline and the arrowhead are built for the zoom. (Dashed until the 6.2.0 redesign.)
        let arrival = item(try procedure(named: "ARR SECTOR EAST"), arrow: .atStart)
        let fixed = VFRMapLayer.overlays(for: arrival)
        XCTAssertEqual(fixed.count, 3)
        let sector = try XCTUnwrap(fixed.first as? VFRSectorOverlay)
        XCTAssertEqual(sector.areaKind, .corridor)
        XCTAssertEqual(fixed.compactMap { ($0 as? VFRRouteLineOverlay)?.stroke }, [.casing, .core])
        let scaled = VFRMapLayer.scaledOverlays(for: arrival, zoom: tenMetersAPoint)
        XCTAssertEqual(scaled.compactMap { ($0 as? VFRDashOverlay)?.role }, [.sectorOutline])
        XCTAssertEqual(scaled.filter { $0 is VFRRouteOverlay }.count, 1, "the arrowhead, one filled triangle")
        XCTAssertTrue((fixed + scaled).allSatisfy { ($0 as? VFRProcedureShape)?.procedureId == sector.procedureId })

        // A glider circuit is dashed, so built for the zoom too; a helicopter route dotted.
        XCTAssertTrue(VFRMapLayer.overlays(for: item(try procedure(named: "TFC GLIDER 14R/32L"))).isEmpty)
        XCTAssertEqual(VFRMapLayer.scaledOverlays(for: item(try procedure(named: "TFC GLIDER 14R/32L")), zoom: tenMetersAPoint)
            .compactMap { ($0 as? VFRDashOverlay)?.role }, [.circuit, .circuit])

        // A noise-abatement area: its outline fixed, its hatch ticks for the zoom.
        let noise = try JSONDecoder().decode(VFRProcedure.self, from: Data("""
        {"id": "n", "ad": "LOAV", "kind": "arr", "name": "S-ARR", "cat": null, "line": [[16.28, 47.94], [16.26, 47.96]],
         "areas": [{"kind": "noise", "poly": [[16.275, 47.9456], [16.2872, 47.9456], [16.2872, 47.9533]]}]}
        """.utf8))
        XCTAssertEqual(VFRMapLayer.overlays(for: item(noise)).compactMap { ($0 as? VFRSectorOverlay)?.areaKind }, [.noise])
        let hatch = try XCTUnwrap(VFRMapLayer.scaledOverlays(for: item(noise), zoom: tenMetersAPoint)
            .compactMap { $0 as? VFRDashOverlay }.first { $0.role == .hatch })
        XCTAssertGreaterThan(hatch.polylines.count, 20)
    }

    /// Dashes cut at the map's zoom: 10 pt on, 6 pt off, at 10 m a point.
    func testTheDashesAreCutForTheZoom() {
        let start = CLLocationCoordinate2D(latitude: 47, longitude: 7)
        let perMeter = MKMapPointsPerMeterAtLatitude(47)
        let end = MKMapPoint(x: MKMapPoint(start).x + 1_000 * perMeter, y: MKMapPoint(start).y).coordinate   // 1 km east
        let pieces = VFRMapLayer.dashes(along: [start, end], pattern: [10, 6], zoom: tenMetersAPoint)
        // 1000 m in 160 m periods: six whole dashes and a 40 m start of the seventh.
        XCTAssertEqual(pieces.count, 7)
        guard pieces.count == 7, let firstDash = pieces.first, let firstEnd = firstDash.last,
              let second = pieces[1].first else { return }
        XCTAssertEqual(MKMapPoint(firstDash[0]).distance(to: MKMapPoint(firstEnd)), 100, accuracy: 0.5)
        XCTAssertEqual(MKMapPoint(second).distance(to: MKMapPoint(start)), 160, accuracy: 0.5)
        // Round a corner: the dash keeps its length, with the corner in it.
        let corner = MKMapPoint(x: MKMapPoint(start).x + 50 * perMeter, y: MKMapPoint(start).y).coordinate
        let south = MKMapPoint(x: MKMapPoint(corner).x, y: MKMapPoint(corner).y + 200 * perMeter).coordinate
        let bent = VFRMapLayer.dashes(along: [start, corner, south], pattern: [10, 6], zoom: tenMetersAPoint)
        XCTAssertEqual(bent.first?.count, 3, "start, corner, end")
        XCTAssertTrue(VFRMapLayer.dashes(along: [start], pattern: [10, 6], zoom: tenMetersAPoint).isEmpty)
    }

    /// The arrowhead: a filled triangle on the drawn line's end, 12 pt long at the map's zoom, pointing
    /// along it.
    func testTheArrowheadIsAChevronSizedForTheZoom() throws {
        let arrival = item(try procedure(named: "ARR SECTOR EAST"), arrow: .atEnd)
        let overlays = VFRMapLayer.arrowheadOverlays(for: arrival, zoom: tenMetersAPoint)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual((overlays.first as? VFRRouteOverlay)?.pointCount, 3)

        let chevron = try XCTUnwrap(VFRMapLayer.chevron(for: arrival, lengthMeters: 120))
        XCTAssertEqual(chevron.count, 3)
        guard chevron.count == 3 else { return }
        let tip = try XCTUnwrap(arrival.procedure.line.last)
        XCTAssertEqual(chevron[1].latitude, tip.latitude, accuracy: 1e-9)
        XCTAssertEqual(chevron[1].longitude, tip.longitude, accuracy: 1e-9)
        for wing in [chevron[0], chevron[2]] {
            XCTAssertEqual(MKMapPoint(wing).distance(to: MKMapPoint(chevron[1])), 120, accuracy: 1)
        }
        // The wings trail behind the tip: toward the line's previous point.
        let before = arrival.procedure.line[arrival.procedure.line.count - 2].coordinate
        XCTAssertLessThan(MKMapPoint(before).distance(to: MKMapPoint(chevron[0])),
                          MKMapPoint(before).distance(to: MKMapPoint(chevron[1])))

        XCTAssertNil(VFRMapLayer.chevron(for: item(try procedure(named: "TC")), lengthMeters: 120), "no arrow on a circuit")
        XCTAssertEqual(VFRMapLayer.Zoom(metersPerPoint: 10), VFRMapLayer.Zoom(metersPerPoint: 10.5), "same half step")
        XCTAssertNotEqual(VFRMapLayer.Zoom(metersPerPoint: 10), VFRMapLayer.Zoom(metersPerPoint: 20))
    }

    func testTheStyles() {
        let circuit = VFRLineStyle.style(kind: .circuit, categories: [.powered], approximate: false)
        XCTAssertEqual(circuit, VFRLineStyle(coreWidth: 3, casingWidth: 6, dash: [], isDotted: false, alpha: 1))
        XCTAssertEqual(VFRLineStyle.style(kind: .circuit, categories: [.heavy], approximate: false).dash, [])
        XCTAssertEqual(VFRLineStyle.style(kind: .circuit, categories: [.glider, .ultralight], approximate: false).dash, [9, 6])
        let heli = VFRLineStyle.style(kind: .circuit, categories: [.helicopter], approximate: false)
        XCTAssertTrue(heli.isDotted)
        let arrival = VFRLineStyle.style(kind: .arrival, categories: [.powered], approximate: false)
        XCTAssertEqual(arrival, VFRLineStyle(coreWidth: 2.4, casingWidth: 5.4, dash: [], isDotted: false, alpha: 1),
                       "solid since the 6.2.0 redesign")
        XCTAssertEqual(VFRLineStyle.style(kind: .arrival, categories: [.glider], approximate: false).dash, [9, 6])
        XCTAssertEqual(arrival.arrowhead.dash, [], "the chevron is solid")
        let approximate = VFRLineStyle.style(kind: .departure, categories: [.powered], approximate: true)
        XCTAssertLessThan(approximate.coreWidth, arrival.coreWidth, "approx is thinner")
        XCTAssertLessThan(approximate.alpha, 1, "and lighter")
    }

    /// The renderer branch comes before every map's generic `MKPolyline` branch (the flown track on the
    /// navigation maps, magenta in the builder): each map gets the procedures' renderers, MapKit's own,
    /// without a dash pattern (which MapKit rasterizes).
    func testEveryMapDrawsThemWithTheirOwnRenderers() throws {
        let map = MKMapView()
        let arrival = item(try procedure(named: "ARR SECTOR EAST"))
        let fixed = VFRMapLayer.overlays(for: arrival) + VFRMapLayer.overlays(for: item(try procedure(named: "TC")))
        let scaled = VFRMapLayer.scaledOverlays(for: arrival, zoom: tenMetersAPoint)
        let state = SharedMapState()
        let native = NativeMapViewUIKit(selectedLayer: .standard, mapState: state, currentLocation: nil, gpsTrack: [],
                                        isFollowingAircraft: .constant(true)).makeCoordinator()
        let swiss = SwissMapView(layerType: .icao, mapState: state, currentLocation: nil, gpsTrack: [],
                                 isFollowingAircraft: .constant(true), forceICAOLayer: false).makeCoordinator()
        let builder = RouteBuilderMapView(waypoints: [], mapLayer: .icao, airports: [], fitRouteToken: 0,
                                          region: .constant(region(spanNM: 10))).makeCoordinator()
        let renderers: [(String, (MKOverlay) -> MKOverlayRenderer)] = [
            ("NativeMapViewUIKit", { native.mapView(map, rendererFor: $0) }),
            ("SwissMapView", { swiss.mapView(map, rendererFor: $0) }),
            ("RouteBuilderMapView", { builder.mapView(map, rendererFor: $0) }),
        ]
        // fixed: the sector's fill, the arrival's casing and core, the circuit's casing and core. scaled:
        // the sector's outline, the arrival's arrowhead.
        let day = VFRMapPalette.day
        XCTAssertEqual(fixed.count, 5)
        XCTAssertEqual(scaled.count, 2)
        guard fixed.count == 5, scaled.count == 2 else { return }
        for (name, renderer) in renderers {
            let sector = try XCTUnwrap(renderer(fixed[0]) as? MKPolygonRenderer, name)
            XCTAssertEqual(sector.fillColor, day.sectorFill, name)
            let routeCore = try XCTUnwrap(renderer(fixed[2]) as? MKPolylineRenderer, name)
            XCTAssertEqual(routeCore.strokeColor, day.procedure, name)
            XCTAssertEqual(routeCore.lineWidth, 2.4, name)
            XCTAssertNil(routeCore.lineDashPattern, name)
            let casing = try XCTUnwrap(renderer(fixed[3]) as? MKPolylineRenderer, name)
            XCTAssertEqual(casing.strokeColor, day.casing, name)
            XCTAssertEqual(casing.lineWidth, 6, name)
            let core = try XCTUnwrap(renderer(fixed[4]) as? MKPolylineRenderer, name)
            XCTAssertEqual(core.strokeColor, day.procedure, "\(name): the procedure's blue, not the generic branch's colour")
            XCTAssertEqual(core.lineWidth, 3, name)
            let outline = try XCTUnwrap(renderer(scaled[0]) as? MKMultiPolylineRenderer, name)
            XCTAssertEqual(outline.strokeColor, day.sectorStroke, name)
            XCTAssertNil(outline.lineDashPattern, "\(name): cut into dashes, not a raster dash pattern")
            let arrow = try XCTUnwrap(renderer(scaled[1]) as? MKPolygonRenderer, name)
            XCTAssertEqual(arrow.fillColor, day.procedure, name)
            XCTAssertEqual(arrow.strokeColor, day.casing, name)
            // A plain polyline still goes to the map's own branch.
            let plain = try XCTUnwrap(renderer(MKPolyline(coordinates: [CLLocationCoordinate2D](), count: 0)) as? MKPolylineRenderer, name)
            XCTAssertNotEqual(plain.strokeColor, day.procedure, name)
        }
        XCTAssertEqual((VFRMapLayer.renderer(for: fixed[4], palette: .night) as? MKPolylineRenderer)?.strokeColor,
                       VFRMapPalette.night.procedure)

        // The labels: a bitmap at least 44 pt square with a callout, on every map, never a default pin.
        let label = VFRProcedureAnnotation(item: item(try procedure(named: "TC")))
        let views: [(String, MKAnnotationView?)] = [
            ("NativeMapViewUIKit", native.mapView(map, viewFor: label)),
            ("SwissMapView", swiss.mapView(map, viewFor: label)),
            ("RouteBuilderMapView", builder.mapView(map, viewFor: label)),
        ]
        for (name, view) in views {
            let view = try XCTUnwrap(view, name)
            XCTAssertFalse(view is MKMarkerAnnotationView, name)
            let image = try XCTUnwrap(view.image, name)
            XCTAssertGreaterThanOrEqual(image.size.width, 44, name)
            XCTAssertGreaterThanOrEqual(image.size.height, 44, name)
            XCTAssertTrue(view.canShowCallout, name)
            XCTAssertNotNil(view.detailCalloutAccessoryView, name)
        }
    }

    // MARK: - The layer on a map

    /// A map in a window, sized as an iPad's, so it has a zoom.
    private func onScreenMap(delegate: MKMapViewDelegate? = nil, spanNM: Double = 10) -> (MKMapView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1_180))
        window.isHidden = false
        let map = MKMapView(frame: window.bounds)
        map.delegate = delegate
        window.addSubview(map)
        map.setRegion(region(spanNM: spanNM), animated: false)
        map.layoutIfNeeded()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return (map, window)
    }

    func testTheDiffAddsAndRemovesByIdAndSkipsUnchangedContent() throws {
        let map = MKMapView()   // no window, no zoom: only what doesn't depend on it
        let state = VFRMapLayer.State()
        let all = try procedures()
        let first = VFRMapContent.make(candidates: Array(all.prefix(2)), region: region(spanNM: 10),
                                       selection: everything, palette: .day)
        VFRMapLayer.sync(first, on: map, state: state)
        XCTAssertEqual(map.overlays.count, 5, "the circuit's casing and core, the arrival's sector and its line's casing and core")
        XCTAssertEqual(map.annotations.compactMap { $0 as? VFRProcedureAnnotation }.count, 2)
        let circuit = try XCTUnwrap(map.overlays.first { ($0 as? VFRCircuitOverlay)?.stroke == .core })

        // The same content again (a GPS tick): nothing touched.
        VFRMapLayer.sync(VFRMapContent.make(candidates: Array(all.prefix(2)), region: region(spanNM: 10),
                                            selection: everything, palette: .day), on: map, state: state)
        XCTAssertTrue(map.overlays.contains { $0 === circuit })

        // The arrival goes, LSGR's circuit comes; LSZQ's circuit stays the same object.
        let second = VFRMapContent.make(candidates: [all[0], all[2]], region: region(spanNM: 10),
                                        selection: everything, palette: .day)
        VFRMapLayer.sync(second, on: map, state: state)
        XCTAssertEqual(map.overlays.count, 4)
        XCTAssertTrue(map.overlays.contains { $0 === circuit })
        XCTAssertFalse(map.overlays.contains { $0 is VFRSectorOverlay })

        // Labels off past 20 NM; the lines stay.
        let wider = VFRMapContent.make(candidates: [all[0], all[2]], region: region(spanNM: 30),
                                       selection: everything, palette: .day)
        VFRMapLayer.sync(wider, on: map, state: state)
        XCTAssertEqual(map.overlays.count, 4)
        XCTAssertTrue(map.annotations.compactMap { $0 as? VFRProcedureAnnotation }.isEmpty)

        // Night: everything again, in the night palette.
        let night = VFRMapContent.make(candidates: [all[0], all[2]], region: region(spanNM: 10),
                                       selection: everything, palette: .night)
        VFRMapLayer.sync(night, on: map, state: state)
        XCTAssertEqual(state.palette, .night)
        XCTAssertEqual(map.overlays.count, 4)
        XCTAssertFalse(map.overlays.contains { $0 === circuit }, "redrawn for the new palette")
        XCTAssertEqual(map.annotations.compactMap { $0 as? VFRProcedureAnnotation }.count, 2)

        // Switched off.
        VFRMapLayer.sync(.empty(.night), on: map, state: state)
        XCTAssertTrue(map.overlays.isEmpty)
        XCTAssertTrue(map.annotations.isEmpty)
    }

    /// On screen, MapKit asks the map's coordinator for a renderer while the sync is adding the overlay,
    /// and the coordinator reads the layer's palette then. With the state passed `inout` that was an
    /// exclusivity violation: the app crashed on the first procedure drawn. Every map, in a window; and
    /// a new zoom redraws what is built for it, nothing else.
    func testAMapOnScreenDrawsThemWhileTheyAreAdded() throws {
        let content = VFRMapContent.make(candidates: try procedures(), region: region(spanNM: 10),
                                         selection: everything, palette: .day)
        let state = SharedMapState()
        let native = NativeMapViewUIKit(selectedLayer: .standard, mapState: state, currentLocation: nil, gpsTrack: [],
                                        isFollowingAircraft: .constant(true)).makeCoordinator()
        let swiss = SwissMapView(layerType: .icao, mapState: state, currentLocation: nil, gpsTrack: [],
                                 isFollowingAircraft: .constant(true), forceICAOLayer: false).makeCoordinator()
        let builder = RouteBuilderMapView(waypoints: [], mapLayer: .icao, airports: [], fitRouteToken: 0,
                                          region: .constant(region(spanNM: 10))).makeCoordinator()
        let maps: [(String, MKMapViewDelegate, VFRMapLayer.State)] = [
            ("NativeMapViewUIKit", native, native.vfrLayer),
            ("SwissMapView", swiss, swiss.vfrLayer),
            ("RouteBuilderMapView", builder, builder.vfrLayer),
        ]
        for (name, delegate, layer) in maps {
            let (map, _) = onScreenMap(delegate: delegate)
            VFRMapLayer.sync(content, on: map, state: layer)
            let fixed = map.overlays.filter { ($0 as? VFRProcedureShape)?.isScaled == false }
            let scaled = map.overlays.filter { ($0 as? VFRProcedureShape)?.isScaled == true }
            XCTAssertEqual(fixed.count, 3 * 2 + 1 + 2 * 2, "\(name): three solid circuits cased, a sector's fill, two solid routes cased")
            // The sector's outline; three dashed or dotted lines cased; three routes' arrowheads.
            XCTAssertEqual(scaled.count, 1 + 3 * 2 + 3, name)
            XCTAssertTrue(map.overlays.contains { ($0 as? VFRCircuitOverlay)?.stroke == .core
                && (map.renderer(for: $0) as? MKPolylineRenderer)?.strokeColor == VFRMapPalette.day.procedure },
                          "\(name): drawn as added")

            // Zoomed in: what is built for the zoom, again; the rest stays as it is.
            map.setRegion(region(spanNM: 3), animated: false)
            VFRMapLayer.sync(content, on: map, state: layer)
            XCTAssertTrue(fixed.allSatisfy { shape in map.overlays.contains { $0 === shape } }, name)
            XCTAssertFalse(scaled.contains { shape in map.overlays.contains { $0 === shape } }, name)
            XCTAssertEqual(map.overlays.filter { ($0 as? VFRProcedureShape)?.isScaled == true }.count, scaled.count, name)
            map.removeFromSuperview()
        }
    }

    func testTheProceduresStayUnderTheRouteAndTheTrack() throws {
        let (map, _) = onScreenMap()
        let route = FlightPlanRoutePolyline(coordinates: [CLLocationCoordinate2D(latitude: 47, longitude: 7),
                                                          CLLocationCoordinate2D(latitude: 47.5, longitude: 7.5)], count: 2)
        let track = GPSTrackPolyline(coordinates: [CLLocationCoordinate2D(latitude: 47, longitude: 7),
                                                   CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1)], count: 2)
        map.addOverlay(route, level: .aboveLabels)
        map.addOverlay(track, level: .aboveLabels)
        let state = VFRMapLayer.State()
        VFRMapLayer.sync(VFRMapContent.make(candidates: try procedures(), region: region(spanNM: 10),
                                            selection: everything, palette: .day), on: map, state: state)
        let stack = map.overlays(in: .aboveLabels)
        let routeIndex = try XCTUnwrap(stack.firstIndex { $0 === route })
        let lastProcedure = try XCTUnwrap(stack.lastIndex { $0 is VFRProcedureShape })
        XCTAssertLessThan(lastProcedure, routeIndex, "under the route")
        // Bottom to top, whatever the order the procedures came in: tiers never go down.
        let tiers = stack.compactMap { VFRMapLayer.tier(of: $0) }
        XCTAssertEqual(tiers, tiers.sorted())
        XCTAssertEqual(Set(tiers), [0, 1, 2, 3, 5, 6, 7], "sectors, outlines, route casings and cores, arrowheads, circuits")
    }

    /// The builder's three redraws (`updateRoute`, `redrawDragRoute`, `redrawCommittedRoute`) and the
    /// Swiss map's layer switch take off their own lines only.
    func testTheRouteRedrawsKeepTheProcedures() throws {
        let (map, _) = onScreenMap()
        let state = VFRMapLayer.State()
        VFRMapLayer.sync(VFRMapContent.make(candidates: try procedures(), region: region(spanNM: 10),
                                            selection: everything, palette: .day), on: map, state: state)
        let procedures = map.overlays.count
        XCTAssertGreaterThan(procedures, 20)
        let coordinates = [CLLocationCoordinate2D(latitude: 47, longitude: 7), CLLocationCoordinate2D(latitude: 47.2, longitude: 7.2)]
        map.addOverlay(RouteCasingPolyline(coordinates: coordinates, count: 2), level: .aboveLabels)
        map.addOverlay(RouteLinePolyline(coordinates: coordinates, count: 2), level: .aboveLabels)
        map.addOverlay(SelectedLegPolyline(coordinates: coordinates, count: 2), level: .aboveLabels)

        RouteBuilderMapView.removeRouteOverlays(from: map)
        XCTAssertEqual(map.overlays.count, procedures)
        XCTAssertTrue(map.overlays.allSatisfy { $0 is VFRProcedureShape })

        let route = FlightPlanRoutePolyline(coordinates: coordinates, count: 2)
        map.addOverlay(route, level: .aboveLabels)
        map.addOverlay(GPSTrackPolyline(coordinates: coordinates, count: 2), level: .aboveLabels)
        SwissMapView.removeTrackForRecolour(on: map)
        XCTAssertEqual(map.overlays.count, procedures + 1, "the track only")
        XCTAssertTrue(map.overlays.contains { $0 === route })
    }

    // MARK: - Callout and report

    func testTheCalloutSaysWhatItIsAndWhereItComesFrom() throws {
        XCTAssertEqual(VFRProcedureCallout.summary(for: item(try procedure(named: "TC"))), "Traffic circuit · 2900 ft · LSZQ")
        XCTAssertEqual(VFRProcedureCallout.summary(for: item(try procedure(named: "ARR SECTOR EAST"))), "VFR arrival · Sector · LSZQ")
        XCTAssertEqual(VFRProcedureCallout.summary(for: item(try procedure(named: "DEP 06"))), "VFR departure · LSGC")
        let lszq = item(try procedure(named: "TC"))
        XCTAssertEqual(VFRProcedureCallout.sourceLine(for: lszq), "open flightmaps · AIRAC 2610 · indicative, check the official chart")
        let noCycle = VFRMapItem(procedure: lszq.procedure, arrow: .none, labelText: "2900 ft", labelAnchor: lszq.labelAnchor,
                                 country: "CH", region: nil, airac: nil)
        XCTAssertEqual(VFRProcedureCallout.sourceLine(for: noCycle), "open flightmaps · indicative, check the official chart")

        XCTAssertEqual(VFRMapStrings.credit(cycles: ["2610", "2610"]),
                       "Circuits & VFR routes © open flightmaps · AIRAC 2610 · indicative")
        XCTAssertEqual(VFRMapStrings.credit(cycles: ["2611", "2610"]),
                       "Circuits & VFR routes © open flightmaps · AIRAC 2610/2611 · indicative")
        XCTAssertEqual(VFRMapStrings.credit(cycles: []), "Circuits & VFR routes © open flightmaps · indicative")

        let view = VFRProcedureCallout.detailView(for: lszq, at: lszq.labelAnchor.coordinate)
        let buttons = allSubviews(of: view).compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.compactMap { $0.configuration?.title }, [L10n.VFRMap.reportError])
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    func testTheReportPrefillsOpenFlightmapsForm() throws {
        let lszq = item(try procedure(named: "TC"))
        let report = OFMErrorReport(item: lszq, position: lszq.labelAnchor.coordinate)
        XCTAssertEqual(report.body, """
        Region: LSAS (CH)
        AIRAC: 2610
        Aerodrome: LSZQ
        Procedure: TC (traffic circuit)
        OFM id: f2fbd4ca-1edb-354d-414d-28863037c1ea
        Map position: 47.40284 N, 6.98375 E
        Reported from AeroCheck (aerocheck.app). What is wrong:

        """)
        XCTAssertFalse(report.body.contains("@"), "nothing about the pilot")

        let form = OFMIndex.ReportForm(url: URL(string: "https://docs.google.com/forms/d/e/x/viewform?usp=sf_link")!,
                                       field: "entry.284686808")
        let url = try XCTUnwrap(report.url(form: form, mail: "info@openflightmaps.org"))
        XCTAssertEqual(url.host, "docs.google.com")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["usp", "entry.284686808"], "the form's own query kept, one field added")
        XCTAssertEqual(items.last?.value, report.body, "decodes back to the text")
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertFalse(url.absoluteString.contains("+"), "a + would read as a space")

        // `+`, `&` and `=` in a name can't break the query.
        XCTAssertEqual(OFMErrorReport.encode("A+B & C=D"), "A%2BB%20%26%20C%3DD")

        // No form, or one that isn't HTTPS: a mail, to the index's address or OFM's.
        for badForm in [nil, OFMIndex.ReportForm(url: URL(string: "http://example.com/form")!, field: "entry.1")] {
            let mail = try XCTUnwrap(report.url(form: badForm, mail: "errors@openflightmaps.org"))
            XCTAssertEqual(mail.scheme, "mailto")
            let components = try XCTUnwrap(URLComponents(url: mail, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "errors@openflightmaps.org")
            XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, report.body)
            XCTAssertEqual(components.queryItems?.first { $0.name == "subject" }?.value, "open flightmaps data: LSZQ TC")
        }
        let fallback = try XCTUnwrap(report.url(form: nil, mail: "x@y.org?cc=someone@else.org"))
        XCTAssertEqual(URLComponents(url: fallback, resolvingAgainstBaseURL: false)?.path, OFMErrorReport.defaultMail,
                       "an address that would add a recipient isn't used")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(report.url(form: nil, mail: nil)), resolvingAgainstBaseURL: false)?.path,
                       "info@openflightmaps.org")
    }

    // MARK: - Sectors, badges and the approach view (6.2.0, the author's design "C with E")

    /// LSZQ's east arrival, as the server's file gives it (`dir`, `offCircuit`, the sector's `label`):
    /// drawn from where it leaves its sector to where it meets the circuit (its third vertex, the
    /// north-east corner), not round the circuit; its letter in a badge at the sector's label point; the
    /// arrowhead at the join. Before, its name sat halfway along the whole line, on the downwind.
    func testAnArrivalIsDrawnOffTheCircuitWithItsLetterInItsSector() throws {
        let arrival = try procedure(named: "ARR SECTOR EAST")
        XCTAssertEqual(arrival.direction, "E")
        XCTAssertEqual(arrival.offCircuit, 0...2)
        let lszq = CLLocationCoordinate2D(latitude: 47.3925, longitude: 7.0286)
        let item = VFRMapItem.drawn(arrival, field: lszq, country: "CH", region: "LSAS", airac: "2610")
        XCTAssertEqual(item.labelStyle, .badge)
        XCTAssertEqual(item.labelText, "E")
        XCTAssertEqual(item.arrow, .atEnd)
        let sector = try XCTUnwrap(arrival.areas.first)
        XCTAssertEqual(item.labelAnchor, VFRCoordinate(latitude: 47.39044, longitude: 7.09321), "the badge at the sector's label")
        XCTAssertTrue(VFRSectorGeometry.contains(item.labelAnchor, sector.polygon), "inside its sector")
        let end = try XCTUnwrap(item.line.last)
        XCTAssertEqual(end, arrival.line[2], "it stops where it meets the circuit")
        let start = try XCTUnwrap(item.line.first)
        XCTAssertLessThan(meters(from: start, to: sector.polygon + [sector.polygon[0]]), 30, "it starts on the sector's edge")
        XCTAssertFalse(item.line.dropFirst().contains { VFRSectorGeometry.contains($0, sector.polygon) }, "never through the badge")

        // A route without a direction keeps its name; a circuit gets its altitude on the downwind's middle.
        let heli = VFRMapItem.drawn(try procedure(named: "ECHO (REGA)"), field: nil, country: "CH", region: nil, airac: nil)
        XCTAssertEqual(heli.labelStyle, .name)
        XCTAssertEqual(heli.labelText, "ECHO (REGA)")
        let circuit = VFRMapItem.drawn(try procedure(named: "TC"), field: nil, country: "CH", region: nil, airac: nil)
        guard case .altitude(let leg, let outsideLeft) = circuit.labelStyle else { return XCTFail("an altitude pill") }
        XCTAssertEqual(leg, [VFRCoordinate(latitude: 47.41884, longitude: 7.044), VFRCoordinate(latitude: 47.40447, longitude: 6.98485)],
                       "the downwind, flown west")
        XCTAssertFalse(outsideLeft, "flown west, the outside (north) is on the right")
        XCTAssertEqual(circuit.labelAnchor.latitude, (47.41884 + 47.40447) / 2, accuracy: 1e-9)

        // Another file's answers are taken as they are.
        let published = try JSONDecoder().decode(VFRProcedure.self, from: Data("""
        {"id": "p", "ad": "LSZQ", "kind": "arr", "name": "ARR SEKTOR WEST", "cat": null, "dir": "w", "offCircuit": [0, 1],
         "line": [[6.9433, 47.3782], [6.97, 47.3831], [6.9889, 47.3837]],
         "areas": [{"kind": "corridor", "poly": [[6.9433, 47.3854], [6.9647, 47.3854], [6.9673, 47.3784], [6.9472, 47.3731]],
                    "label": [6.95283, 47.3802]}]}
        """.utf8))
        XCTAssertEqual(published.direction, "W")
        XCTAssertEqual(published.offCircuit, 0...1)
        XCTAssertEqual(published.areas.first?.labelPoint, VFRCoordinate(latitude: 47.3802, longitude: 6.95283))
        let west = VFRMapItem.drawn(published, field: lszq, country: "CH", region: nil, airac: nil)
        XCTAssertEqual(west.labelAnchor, VFRCoordinate(latitude: 47.3802, longitude: 6.95283))
        XCTAssertEqual(west.line.last, published.line[1])
        // Nonsense from a file is ignored, not trusted.
        let odd = try JSONDecoder().decode(VFRProcedure.self, from: Data("""
        {"id": "q", "ad": "LSZQ", "kind": "arr", "name": "ARR", "cat": null, "dir": "UP", "offCircuit": [2, 1],
         "line": [[6.9433, 47.3782], [6.97, 47.3831], [6.9889, 47.3837]]}
        """.utf8))
        XCTAssertNil(odd.direction)
        XCTAssertNil(odd.offCircuit)
    }

    /// The app works none of it out: without `dir` a route keeps its name, even one that says EAST;
    /// without the sector's `label` the letter goes where the arrival starts; without `offCircuit` the
    /// whole line is drawn. The server's job gives all three.
    func testWithoutTheServersFieldsTheMapFallsBackToTheName() throws {
        let bare = try JSONDecoder().decode(VFRProcedure.self, from: Data("""
        {"id": "r", "ad": "LSZQ", "kind": "arr", "name": "ARR SECTOR EAST", "cat": null,
         "line": [[7.10158, 47.38718], [7.07828, 47.39336], [7.05721, 47.39871], [7.05612, 47.39946], [7.04636, 47.41809]],
         "areas": [{"kind": "corridor", "poly": [[7.10449, 47.39655], [7.07946, 47.39518], [7.07946, 47.39206], [7.09685, 47.38044]]}]}
        """.utf8))
        let named = VFRMapItem.drawn(bare, field: nil, country: "CH", region: nil, airac: nil)
        XCTAssertEqual(named.labelStyle, .name)
        XCTAssertEqual(named.labelText, "ARR SECTOR EAST")
        XCTAssertEqual(named.line.last, bare.line.last, "drawn to the end of its line")

        let lettered = try JSONDecoder().decode(VFRProcedure.self, from: Data("""
        {"id": "s", "ad": "LSZQ", "kind": "arr", "name": "ARR SECTOR EAST", "cat": null, "dir": "E",
         "line": [[7.10158, 47.38718], [7.07828, 47.39336], [7.05721, 47.39871]],
         "areas": [{"kind": "corridor", "poly": [[7.10449, 47.39655], [7.07946, 47.39518], [7.07946, 47.39206], [7.09685, 47.38044]]}]}
        """.utf8))
        let badge = VFRMapItem.drawn(lettered, field: CLLocationCoordinate2D(latitude: 47.3925, longitude: 7.0286),
                                     country: "CH", region: nil, airac: nil)
        XCTAssertEqual(badge.labelStyle, .badge)
        XCTAssertEqual(badge.labelText, "E")
        XCTAssertEqual(badge.labelAnchor, badge.line.first, "where the arrival starts, at its sector's edge")
    }

    /// Metres from `point` to the nearest point of `polyline`, on the flat projection the map uses.
    private func meters(from point: VFRCoordinate, to polyline: [VFRCoordinate]) -> Double {
        zip(polyline, polyline.dropFirst()).map { a, b in
            let k = cos(point.latitude * .pi / 180)
            let (ax, ay, bx, by) = (a.longitude * k, a.latitude, b.longitude * k, b.latitude)
            let (px, py) = (point.longitude * k, point.latitude)
            let (dx, dy) = (bx - ax, by - ay)
            let t = dx == 0 && dy == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
            return hypot(ax + t * dx - px, ay + t * dy - py) * 111_320
        }.min() ?? .infinity
    }

    /// The altitude pill turns with the downwind and stays upright, outside the circuit, whichever way
    /// the map is turned (track up).
    func testTheAltitudeTurnsAlongTheDownwindUprightAndOutside() {
        let west = [VFRCoordinate(latitude: 47.41884, longitude: 7.044), VFRCoordinate(latitude: 47.40447, longitude: 6.98485)]
        let northUp = VFRMapLayer.labelTurn(leg: west, outsideLeft: false, heading: 0)
        XCTAssertLessThanOrEqual(abs(northUp.angle), .pi / 2, "upright")
        XCTAssertTrue(northUp.above, "north up, the outside (north) is above")
        let southUp = VFRMapLayer.labelTurn(leg: west, outsideLeft: false, heading: 180)
        XCTAssertLessThanOrEqual(abs(southUp.angle), .pi / 2)
        XCTAssertFalse(southUp.above, "turned round, north is below")
        XCTAssertEqual(northUp.angle, southUp.angle, accuracy: 1e-9, "the same slant, upright both ways")
        let east = VFRMapLayer.labelTurn(leg: [VFRCoordinate(latitude: 47, longitude: 7), VFRCoordinate(latitude: 47, longitude: 7.1)],
                                         outsideLeft: true, heading: 90)
        XCTAssertEqual(abs(east.angle), .pi / 2, accuracy: 1e-6, "flown east with east up: upright, on its side")
    }

    /// Open flightmaps' thresholds pair into runways; the runway in use lands into the wind; the
    /// circuit, drawn for 07 at LSZQ, is flown as drawn for 07 and the other way round for 25.
    func testTheRunwayInUseAndTheCircuitsDirection() throws {
        let thresholds = [VFRThreshold(runway: "07", position: VFRCoordinate(latitude: 47.39125, longitude: 7.02427), trueBearing: 70),
                          VFRThreshold(runway: "25", position: VFRCoordinate(latitude: 47.39356, longitude: 7.03373), trueBearing: 250)]
        let runways = VFRRunwayEnds.runways(thresholds: thresholds, airportRunways: [], reference: nil)
        XCTAssertEqual(runways.count, 1)
        XCTAssertEqual(VFRRunwayEnds.endInUse(of: runways, windFrom: 240)?.ident, "25")
        XCTAssertEqual(VFRRunwayEnds.endInUse(of: runways, windFrom: 90)?.ident, "07")
        XCTAssertNil(VFRRunwayEnds.endInUse(of: runways, windFrom: nil), "variable or unknown: none")

        let circuit = try procedure(named: "TC")
        let for07 = VFRApproachField.directionArrows(on: circuit.line, landing: 70)
        XCTAssertEqual(for07.count, 2)
        let west = VFRSectorGeometry.bearing(VFRCoordinate(latitude: 47.41884, longitude: 7.044),
                                             VFRCoordinate(latitude: 47.40447, longitude: 6.98485))
        XCTAssertEqual(for07.first.map { VFRSectorGeometry.angle($0.bearing, west) } ?? 180, 0, accuracy: 1, "downwind flown west for 07")
        let for25 = VFRApproachField.directionArrows(on: circuit.line, landing: 250)
        XCTAssertEqual(for25.first.map { VFRSectorGeometry.angle($0.bearing, west) } ?? 0, 180, accuracy: 1, "the other way for 25")
        XCTAssertTrue(VFRApproachField.directionArrows(on: circuit.line, landing: 160).isEmpty, "a crossing runway: none")

        // Open flightmaps' thresholds, the airport database's designators: LSGE is 10/28 in its file, 09/27
        // everywhere else.
        let lsgeRunway = Runway(id: 2, airportRef: 2, airportIdent: "LSGE", lengthFt: 2625, widthFt: 59, surface: "ASP",
                                lighted: false, closed: false, leIdent: "09", leLatitude: nil, leLongitude: nil, leElevationFt: nil,
                                leHeadingDegT: 93, leDisplacedThresholdFt: nil, heIdent: "27", heLatitude: nil, heLongitude: nil,
                                heElevationFt: nil, heHeadingDegT: 273, heDisplacedThresholdFt: nil,
                                pcn: nil, leToraFt: nil, leLdaFt: nil, heToraFt: nil, heLdaFt: nil)
        let lsge = VFRRunwayEnds.runways(
            thresholds: [VFRThreshold(runway: "10", position: VFRCoordinate(latitude: 46.75559, longitude: 7.07063), trueBearing: 95),
                         VFRThreshold(runway: "28", position: VFRCoordinate(latitude: 46.75495, longitude: 7.08091), trueBearing: 275)],
            airportRunways: [lsgeRunway], reference: nil)
        XCTAssertEqual(lsge.first.map { [$0.first.ident, $0.second.ident] }, ["09", "27"])

        // The approach view keeps the longest runway, and the one in use.
        let short = VFRRunwayEnds(first: .init(ident: "14R", threshold: VFRCoordinate(latitude: 46.918, longitude: 7.492), trueBearing: 140),
                                  second: .init(ident: "32L", threshold: VFRCoordinate(latitude: 46.915, longitude: 7.496), trueBearing: 320))
        let kept = VFRApproachField.make(ident: "LSZQ", reference: VFRCoordinate(latitude: 47.3925, longitude: 7.02889),
                                         runways: runways + [short], circuits: [], windFrom: nil, parachuting: false)
        XCTAssertEqual(kept.runways, runways, "the longest only")
        let inUse = VFRApproachField.make(ident: "LSZQ", reference: VFRCoordinate(latitude: 47.3925, longitude: 7.02889),
                                          runways: runways + [short], circuits: [], windFrom: 140, parachuting: false)
        XCTAssertEqual(inUse.runways.count, 2, "and the one in use")
        XCTAssertEqual(inUse.runwayInUse, "14R")

        // Without thresholds: the airport database's ends, else the reference point, heading and length.
        let noEnds = Runway(id: 1, airportRef: 1, airportIdent: "LSZQ", lengthFt: 2625, widthFt: 59, surface: "ASP",
                            lighted: false, closed: false, leIdent: "07", leLatitude: nil, leLongitude: nil, leElevationFt: nil,
                            leHeadingDegT: 70, leDisplacedThresholdFt: nil, heIdent: "25", heLatitude: nil, heLongitude: nil,
                            heElevationFt: nil, heHeadingDegT: 250, heDisplacedThresholdFt: nil,
                            pcn: nil, leToraFt: nil, leLdaFt: nil, heToraFt: nil, heLdaFt: nil)
        let estimated = VFRRunwayEnds.runways(thresholds: [], airportRunways: [noEnds],
                                              reference: VFRCoordinate(latitude: 47.3925, longitude: 7.02889))
        XCTAssertEqual(estimated.count, 1)
        if let runway = estimated.first {
            XCTAssertEqual(VFRSectorGeometry.meters(runway.first.threshold, runway.second.threshold), 2625 * 0.3048, accuracy: 2)
        }
    }

    /// The approach view: the fade under everything, the extended centreline, the direction arrowheads
    /// over the circuit, the runway numbers (the runway in use filled) and the parachute, never hidden.
    func testTheApproachViewDrawsItsFadeCentrelineNumbersAndParachute() throws {
        let circuit = try procedure(named: "TC")
        let runways = VFRRunwayEnds.runways(
            thresholds: [VFRThreshold(runway: "07", position: VFRCoordinate(latitude: 47.39125, longitude: 7.02427), trueBearing: 70),
                         VFRThreshold(runway: "25", position: VFRCoordinate(latitude: 47.39356, longitude: 7.03373), trueBearing: 250)],
            airportRunways: [], reference: nil)
        let field = VFRApproachField.make(ident: "LSZQ", reference: VFRCoordinate(latitude: 47.3925, longitude: 7.02889),
                                          runways: runways, circuits: [circuit], windFrom: 80, parachuting: true)
        XCTAssertEqual(field.runwayInUse, "07")
        XCTAssertEqual(field.arrows.count, 2)
        let spot = try XCTUnwrap(field.parachutePosition)
        XCTAssertLessThan(spot.latitude, 47.3925, "beside the field, away from the circuit (north of it)")

        let fixed = VFRMapLayer.approachOverlays(for: field)
        XCTAssertTrue(fixed.first is VFRFadeOverlay)
        XCTAssertEqual(fixed.compactMap { VFRMapLayer.tier(of: $0) }, [-1], "under the sectors")
        let scaled = VFRMapLayer.approachScaledOverlays(for: field, zoom: tenMetersAPoint)
        XCTAssertEqual(scaled.compactMap { ($0 as? VFRDashOverlay)?.role }, [.centreline])
        let heads = scaled.compactMap { $0 as? VFRRouteOverlay }
        XCTAssertEqual(heads.count, 2)
        XCTAssertTrue(heads.allSatisfy { $0.onCircuit && VFRMapLayer.tier(of: $0) == 8 }, "over the circuit")

        let labels = VFRApproachAnnotation.annotations(for: field)
        XCTAssertEqual(labels.map(\.kind), [.runway("07", inUse: true), .runway("25", inUse: false), .parachute])
        let west = try XCTUnwrap(labels.first)
        XCTAssertLessThan(west.coordinate.longitude, 7.02427, "07's number past the west end, where it is landed from")

        let map = MKMapView()
        for label in labels {
            let view = try XCTUnwrap(VFRMapLayer.annotationView(for: label, on: map, palette: .day))
            XCTAssertEqual(view.displayPriority, .required)
            XCTAssertFalse(view.canShowCallout)
            XCTAssertGreaterThanOrEqual(view.image?.size.width ?? 0, 44)
            XCTAssertNotNil(view.accessibilityLabel)
        }
        XCTAssertEqual(L10n.VFRMap.runwayInUse("07"), "Runway 07, in use")

        // On the map: the content's signature changes with the approach view, and the sync adds and
        // removes its shapes and labels.
        let state = VFRMapLayer.State()
        let plain = VFRMapContent(items: [], showsLabels: true, palette: .day)
        let approach = VFRMapContent(items: [], showsLabels: true, palette: .day, approach: [field])
        XCTAssertNotEqual(plain.signature, approach.signature)
        VFRMapLayer.sync(approach, on: map, state: state)
        XCTAssertTrue(map.overlays.contains { $0 is VFRFadeOverlay })
        XCTAssertEqual(map.annotations.compactMap { $0 as? VFRApproachAnnotation }.count, 3)
        VFRMapLayer.sync(plain, on: map, state: state)
        XCTAssertFalse(map.overlays.contains { $0 is VFRFadeOverlay })
        XCTAssertTrue(map.annotations.isEmpty)
    }

    /// The badge: a 44 pt square (the touch target), never hidden by a collision, with its callout.
    func testTheBadgeIsAFixedSizeTargetWithItsCallout() throws {
        let arrival = VFRMapItem.drawn(try procedure(named: "ARR SECTOR EAST"), field: nil, country: "CH",
                                       region: "LSAS", airac: "2610")
        let view = try XCTUnwrap(VFRMapLayer.annotationView(for: VFRProcedureAnnotation(item: arrival), on: MKMapView(), palette: .day))
        XCTAssertEqual(view.image?.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(view.displayPriority, .required)
        XCTAssertTrue(view.canShowCallout)
        XCTAssertEqual(VFRProcedureCallout.summary(for: arrival), "VFR arrival · Sector · LSZQ")
        // The circuit's altitude, turned: required too, and wider than tall only once turned.
        let circuit = VFRMapItem.drawn(try procedure(named: "TC"), field: nil, country: "CH", region: nil, airac: nil)
        let pill = try XCTUnwrap(VFRMapLayer.annotationView(for: VFRProcedureAnnotation(item: circuit), on: MKMapView(), palette: .day))
        XCTAssertEqual(pill.displayPriority, .required)
        XCTAssertNotEqual(pill.transform, .identity, "turned along the downwind")
    }

    // MARK: - Strings

    func testTheNewStringsHaveTheirFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        let expected = [
            "Aerodrome procedures": "Procédures d’aérodrome",
            "Traffic circuits": "Tours de piste",
            "Arrival & departure routes (with sectors)": "Routes d’arrivée et de départ (avec secteurs)",
            "Glider, UL & helicopter": "Planeurs, ULM et hélicoptères",
            "Download VFR procedures for %@ in Data & Storage": "Téléchargez les procédures VFR pour %@ dans Données et stockage",
            "Circuits & VFR routes © open flightmaps · AIRAC %@ · indicative":
                "Tours de piste et routes VFR © open flightmaps · AIRAC %@ · indicatif",
            "Circuits & VFR routes © open flightmaps · indicative": "Tours de piste et routes VFR © open flightmaps · indicatif",
            "Traffic circuit": "Tour de piste",
            "VFR arrival": "Arrivée VFR",
            "VFR departure": "Départ VFR",
            "Sector": "Secteur",
            "Noise abatement area": "Zone de moindre bruit",
            "Alt: see chart": "Alt. : voir carte",
            "Approximate shape": "Tracé approximatif",
            "open flightmaps · indicative, check the official chart": "open flightmaps · indicatif, vérifiez la carte officielle",
            "open flightmaps · AIRAC %@ · indicative, check the official chart":
                "open flightmaps · AIRAC %@ · indicatif, vérifiez la carte officielle",
            "Report an error": "Signaler une erreur",
            "Runway %@": "Piste %@",
            "Runway %@, in use": "Piste %@, en service",
            "Parachuting": "Parachutisme",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        XCTAssertNotEqual(french.localizedString(forKey: "From open flightmaps, for the countries in Data & Storage. Indicative only: always check the official chart.",
                                                 value: missing, table: nil), missing)
        XCTAssertEqual(L10n.VFRMap.downloadHint("CH"), "Download VFR procedures for CH in Data & Storage")
    }
}
