import MapKit
import MapLibre
import UIKit

// MARK: - The map's lines and areas on MapLibre (6.8.0)

/// `AeroMapView`'s lines and areas drawn by MapLibre (the plan's PR 6): the airspace, the aerodrome procedures, the
/// flown track, the planned route, the route and its diversion line, the track vector. (The aircraft is a marker, above
/// every marker as on MapKit: `PilotMapMarkers`.)
///
/// Nothing here decides a colour or a width. Each group is built as the MapKit view builds it (the same overlay
/// objects, from the same functions) and painted as its MapKit renderer says (`Paint`, read off the renderer the
/// MapKit view would use): the two engines draw the same map until MapKit goes (PR 9). A group is one GeoJSON source
/// and a few style layers, one per tier and paint kind, so MapLibre stacks them as MapKit did: every group above the
/// style's own layers and the charts, in `Group` order, each tier above the one before.
@MainActor
final class PilotMapShapes {
    /// The groups, bottom first.
    enum Group: Int, CaseIterable {
        case airspace
        case procedures
        case track
        case plannedRoute
        case route
        case trackVector

        var sourceID: String { "aero.\(self)" }
    }

    /// One shape: its overlay, the renderer MapKit would draw it with, its tier within the group (higher on top).
    struct Shape {
        let overlay: MKOverlay
        let renderer: MKOverlayRenderer?
        let tier: Int
    }

    /// A shape's paint as its MapKit renderer has it: colours with the renderer's alpha in them, the width and the
    /// dashes in points.
    struct Paint: Equatable {
        var stroke: UIColor?
        var fill: UIColor?
        var width: Double
        var cap: CGLineCap
        var dash: [Double]

        init(stroke: UIColor?, fill: UIColor?, width: Double, cap: CGLineCap = .round, dash: [Double] = []) {
            self.stroke = stroke; self.fill = fill; self.width = width; self.cap = cap; self.dash = dash
        }

        /// What a MapKit path renderer draws; nil for any other renderer.
        init?(_ renderer: MKOverlayRenderer?) {
            guard let renderer = renderer as? MKOverlayPathRenderer else { return nil }
            let alpha = renderer.alpha
            stroke = renderer.strokeColor.map { $0.withAlphaComponent($0.cgColor.alpha * alpha) }
            fill = renderer.fillColor.map { $0.withAlphaComponent($0.cgColor.alpha * alpha) }
            width = Double(renderer.lineWidth)
            cap = renderer.lineCap
            dash = renderer.lineDashPattern?.map(\.doubleValue) ?? []
        }

        /// Draws a line: a colour and a width.
        var strokes: Bool { stroke.map { $0.cgColor.alpha > 0 } ?? false && width > 0 }
        var fills: Bool { fill.map { $0.cgColor.alpha > 0 } ?? false }

        /// MapLibre's dash pattern, in line widths.
        var dashInWidths: [Double] { width > 0 ? dash.map { $0 / width } : [] }
    }

    /// A colour as MapLibre reads it from a feature ("rgba(255,0,204,1)"), in sRGB, a dynamic one as `traits` see it.
    static func css(_ color: UIColor, traits: UITraitCollection) -> String {
        let resolved = color.resolvedColor(with: traits)
        let srgb = resolved.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            ?? resolved.cgColor
        let c = srgb.components ?? [0, 0, 0, 1]
        let (r, g, b, a) = c.count >= 4 ? (c[0], c[1], c[2], c[3]) : (c[0], c[0], c[0], c.count > 1 ? c[1] : 1)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return "rgba(\(byte(r)),\(byte(g)),\(byte(b)),\((min(max(a, 0), 1) * 1000).rounded() / 1000))"
    }

    // MARK: Layers

    /// A style layer of a group: its tier and what it paints.
    struct LayerKey: Hashable, Comparable {
        enum Kind: Hashable {
            case fill
            case line(cap: CGLineCap, dash: [Double])
        }

        let group: Group
        let tier: Int
        let kind: Kind

        var id: String {
            switch kind {
            case .fill: return "\(group.sourceID).\(tier).fill"
            case let .line(cap, dash):
                let pattern = dash.map { String(format: "%.2f", $0) }.joined(separator: "-")
                return "\(group.sourceID).\(tier).line.\(cap.rawValue)" + (dash.isEmpty ? "" : ".\(pattern)")
            }
        }

        private var kindOrder: Int {
            switch kind {
            case .fill: return 0
            case .line: return 1
            }
        }

        static func < (lhs: LayerKey, rhs: LayerKey) -> Bool {
            if lhs.group != rhs.group { return lhs.group.rawValue < rhs.group.rawValue }
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
            return lhs.id < rhs.id
        }
    }

    /// The features a group's shapes make, and the layers they need.
    static func features(for shapes: [Shape], group: Group, traits: UITraitCollection) -> ([MLNShape & MLNFeature], Set<LayerKey>) {
        var features: [MLNShape & MLNFeature] = []
        var keys = Set<LayerKey>()
        for shape in shapes {
            guard let paint = Paint(shape.renderer), paint.strokes || paint.fills,
                  let feature = feature(for: shape.overlay) else { continue }
            var attributes: [String: Any] = [:]
            if paint.fills, let fill = paint.fill {
                let key = LayerKey(group: group, tier: shape.tier, kind: .fill)
                keys.insert(key)
                attributes["fk"] = key.id
                attributes["fill"] = css(fill, traits: traits)
            }
            if paint.strokes, let stroke = paint.stroke {
                let key = LayerKey(group: group, tier: shape.tier, kind: .line(cap: paint.cap, dash: paint.dashInWidths))
                keys.insert(key)
                attributes["lk"] = key.id
                attributes["stroke"] = css(stroke, traits: traits)
                attributes["width"] = paint.width
            }
            feature.attributes = attributes
            features.append(feature)
        }
        return (features, keys)
    }

    /// An overlay's geometry as a MapLibre feature: a polygon (with its holes), several lines, or a line.
    static func feature(for overlay: MKOverlay) -> (MLNShape & MLNFeature)? {
        func coordinates(_ points: MKMultiPoint) -> [CLLocationCoordinate2D] {
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: points.pointCount)
            points.getCoordinates(&coords, range: NSRange(location: 0, length: points.pointCount))
            return coords
        }
        switch overlay {
        case let polygon as MKPolygon:
            let ring = coordinates(polygon)
            guard ring.count >= 3 else { return nil }
            let holes = (polygon.interiorPolygons ?? []).map { hole -> MLNPolygon in
                let coords = coordinates(hole)
                return MLNPolygon(coordinates: coords, count: UInt(coords.count))
            }
            return MLNPolygonFeature(coordinates: ring, count: UInt(ring.count), interiorPolygons: holes)
        case let lines as MKMultiPolyline:
            let parts = lines.polylines.map { line -> MLNPolyline in
                let coords = coordinates(line)
                return MLNPolyline(coordinates: coords, count: UInt(coords.count))
            }
            guard !parts.isEmpty else { return nil }
            return MLNMultiPolylineFeature(polylines: parts)
        case let line as MKPolyline:
            let coords = coordinates(line)
            guard coords.count >= 2 else { return nil }
            return MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
        default:
            return nil
        }
    }

    // MARK: State

    /// What each group last drew, so a pass with nothing new does nothing (a GPS tick, a SwiftUI update).
    private var signatures: [Group: Int] = [:]
    /// The layers on the style, by group.
    private var layers: [Group: Set<LayerKey>] = [:]

    nonisolated init() {}

    /// A new style has none of this: everything is drawn again.
    func reset() {
        signatures = [:]
        layers = [:]
    }

    /// The lowest of these layers: what the charts go under.
    func lowestLayer(in style: MLNStyle) -> MLNStyleLayer? {
        layers.values.flatMap { $0 }.sorted().lazy.compactMap { style.layer(withIdentifier: $0.id) }.first
    }

    /// Draws `group` from `shapes` (built only when `signature` differs from the last one drawn).
    func sync(_ group: Group, signature: Int, on style: MLNStyle, traits: UITraitCollection,
              shapes: @MainActor () -> [Shape]) {
        guard signatures[group] != signature else { return }
        signatures[group] = signature
        let (features, keys) = Self.features(for: shapes(), group: group, traits: traits)
        let source = self.source(for: group, in: style)
        source.shape = MLNShapeCollectionFeature(shapes: features)
        setLayers(keys, for: group, source: source, in: style)
    }

    private func source(for group: Group, in style: MLNStyle) -> MLNShapeSource {
        if let source = style.source(withIdentifier: group.sourceID) as? MLNShapeSource { return source }
        let source = MLNShapeSource(identifier: group.sourceID, shape: nil, options: nil)
        style.addSource(source)
        return source
    }

    /// The group's layers made what `wanted` says: the ones no feature needs any more removed, new ones put in their
    /// place in the stack (`LayerKey`'s order).
    private func setLayers(_ wanted: Set<LayerKey>, for group: Group, source: MLNShapeSource, in style: MLNStyle) {
        let had = layers[group] ?? []
        for key in had.subtracting(wanted) {
            if let layer = style.layer(withIdentifier: key.id) { style.removeLayer(layer) }
        }
        layers[group] = wanted
        for key in wanted.subtracting(had).sorted() {
            let layer = Self.makeLayer(key, source: source)
            let all = layers.values.flatMap { $0 }.sorted()
            if let above = all.first(where: { $0 > key && style.layer(withIdentifier: $0.id) != nil }),
               let sibling = style.layer(withIdentifier: above.id) {
                style.insertLayer(layer, below: sibling)
            } else {
                style.addLayer(layer)
            }
        }
    }

    static func makeLayer(_ key: LayerKey, source: MLNShapeSource) -> MLNStyleLayer {
        switch key.kind {
        case .fill:
            let layer = MLNFillStyleLayer(identifier: key.id, source: source)
            layer.predicate = NSPredicate(format: "fk == %@", key.id)
            layer.fillColor = NSExpression(mglJSONObject: ["to-color", ["get", "fill"]])
            return layer
        case let .line(cap, dash):
            let layer = MLNLineStyleLayer(identifier: key.id, source: source)
            layer.predicate = NSPredicate(format: "lk == %@", key.id)
            layer.lineColor = NSExpression(mglJSONObject: ["to-color", ["get", "stroke"]])
            layer.lineWidth = NSExpression(mglJSONObject: ["get", "width"])
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineCap = NSExpression(forConstantValue: cap == .butt ? "butt" : cap == .square ? "square" : "round")
            if !dash.isEmpty { layer.lineDashPattern = NSExpression(forConstantValue: dash) }
            return layer
        }
    }
}

// MARK: - The groups, as the MapKit view builds them

extension PilotMapShapes {
    /// Every group drawn from `map`'s inputs, as `AeroMapView` would draw them with MapKit.
    func apply(_ map: AeroMapView, on mapView: MLNMapView, style: MLNStyle, routePreview: [CLLocationCoordinate2D]? = nil) {
        let traits = mapView.traitCollection

        // The airspace: each polygon as `AirspacePolygon.style` paints it, the selected one on top.
        let airspace = map.shownAirspace
        let selected = map.shownAirspaceSelection
        sync(.airspace, signature: Self.hash(airspace.map(\.airspaceId), selected), on: style, traits: traits) {
            airspace.map { polygon in
                let renderer = MKPolygonRenderer(polygon: polygon)
                polygon.style(renderer, selected: polygon.airspaceId == selected)
                return Shape(overlay: polygon, renderer: renderer, tier: polygon.airspaceId == selected ? 1 : 0)
            }
        }

        // The aerodrome procedures: `VFRMapLayer`'s overlays for the map's zoom (dashes, ticks and arrowheads are cut
        // for it), in its tiers. Their labels are markers (PR 7).
        let content = map.shownProcedures
        let zoom = Self.vfrZoom(of: mapView)
        sync(.procedures, signature: Self.hash(content.signature, zoom?.step, content.palette.rawValue), on: style,
             traits: traits) {
            var shapes: [Shape] = []
            @MainActor func add(_ overlays: [MKOverlay]) {
                for overlay in overlays {
                    shapes.append(Shape(overlay: overlay, renderer: VFRMapLayer.renderer(for: overlay, palette: content.palette),
                                        tier: VFRMapLayer.tier(of: overlay) ?? 0))
                }
            }
            for item in content.items {
                add(VFRMapLayer.overlays(for: item))
                if let zoom { add(VFRMapLayer.scaledOverlays(for: item, zoom: zoom)) }
            }
            if let zoom {
                for field in content.approach { add(VFRMapLayer.approachScaledOverlays(for: field, zoom: zoom)) }
            }
            return shapes
        }

        // The flown track, in its layer's colour.
        let track = map.shownTrack
        sync(.track, signature: Self.hash(track.count, track.last?.timestamp, map.layerType.rawValue), on: style,
             traits: traits) {
            guard track.count > 1 else { return [] }
            let coords = subsampledTrackCoordinates(track)
            let line = GPSTrackPolyline(coordinates: coords, count: coords.count)
            return [Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType), tier: 0)]
        }

        // The route builder's route: the selected leg's halo, the casing, the core.
        // While a finger drags it, the working geometry, with no leg selected.
        var planned = map.shownPlannedRoute
        if let routePreview {
            planned.waypoints = routePreview.map { FlightPlanWaypoint(coordinate: $0) }
            planned.selectedLeg = nil
        }
        sync(.plannedRoute, signature: Self.hash(planned.waypoints.map { "\($0.latitude),\($0.longitude)" }, planned.selectedLeg),
             on: style, traits: traits) {
            PlannedRouteLayer.lines(for: planned).enumerated().map { tier, line in
                Shape(overlay: line, renderer: PlannedRouteLayer.renderer(for: line), tier: tier)
            }
        }

        // The route (flown dimmed, the rest bright), and the line from the aircraft to a diversion field, kept
        // within 150 m of the aircraft as the MapKit view keeps it.
        let plan = map.shownPlan
        let diversionFrom = plan?.diversion != nil ? map.shownAircraft : nil
        let routeSignature = Self.hash(plan?.waypoints.map { "\($0.latitude),\($0.longitude)" }, plan?.currentWaypointIndex,
                                       plan?.diversion?.ident, diversionFrom.map { Self.cell($0.coordinate) })
        sync(.route, signature: routeSignature, on: style, traits: traits) {
            guard let plan else { return [] }
            var lines = AeroMapView.routePolylines(for: plan)
            if let diversion = plan.diversion, let from = diversionFrom {
                let line = FlightPlanRoutePolyline(coordinates: [from.coordinate, diversion.coordinate], count: 2)
                line.isDiversion = true
                lines.append(line)
            }
            return lines.enumerated().map { tier, line in
                Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType), tier: tier)
            }
        }

        // The track vector over its casing. Kept through a transient empty (a GPS gap, under 5 kt), gone when off.
        let vector = map.trackVectorOverlays
        if !map.shownTrackVector {
            sync(.trackVector, signature: 0, on: style, traits: traits) { [] }
        } else if !vector.isEmpty {
            sync(.trackVector, signature: Self.hash(TrackVectorPolyline.geometry(of: vector)), on: style, traits: traits) {
                vector.map { line in
                    Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType),
                          tier: line is TrackVectorCasingPolyline ? 0 : 1)
                }
            }
        }

    }

    /// The map's zoom as `VFRMapLayer` sizes its arrowheads and dashes: metres per point at the map's middle.
    static func vfrZoom(of mapView: MLNMapView) -> VFRMapLayer.Zoom? {
        guard mapView.bounds.width > 0 else { return nil }
        let metersPerPoint = mapView.metersPerPoint(atLatitude: mapView.centerCoordinate.latitude)
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return nil }
        return VFRMapLayer.Zoom(metersPerPoint: metersPerPoint)
    }

    /// A coordinate's cell about 150 m across: the diversion line is redrawn when the aircraft leaves it.
    static func cell(_ coordinate: CLLocationCoordinate2D) -> String {
        "\((coordinate.latitude / 0.00135).rounded()),\((coordinate.longitude / 0.002).rounded())"
    }

    static func hash(_ values: AnyHashable?...) -> Int {
        var hasher = Hasher()
        for value in values { hasher.combine(value) }
        return hasher.finalize()
    }
}
