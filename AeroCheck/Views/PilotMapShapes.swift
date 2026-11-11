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
        case notams
        case procedures
        case track
        /// The track's live end, from the last whole minute (`splitTrack`).
        case trackTail
        /// From the last recorded point to the aircraft as drawn: the track records a point every 5 s, so the line
        /// ended up to 5 s of flight behind the aircraft (the author, 11 Nov: a hole just behind it, filling again).
        case trackLive
        case plannedRoute
        case route
        /// From the aircraft as drawn to a diversion field: its own two points, so it follows the aircraft without
        /// the route being sent again.
        case diversion
        case trackVector

        var sourceID: String { "aero.\(self)" }
    }

    /// One shape: its overlay, the renderer MapKit would draw it with, its tier within the group (higher on top), and
    /// how strong its hatch is (an R, D or P area's, `PilotMapStyle.hatchImage`), which a renderer can't say.
    struct Shape {
        let overlay: MKOverlay
        let renderer: MKOverlayRenderer?
        let tier: Int
        var hatch: Double = 0
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
            case hatch
            case line(cap: CGLineCap, dash: [Double])
        }

        let group: Group
        let tier: Int
        let kind: Kind

        var id: String {
            switch kind {
            case .fill: return "\(group.sourceID).\(tier).fill"
            case .hatch: return "\(group.sourceID).\(tier).hatch"
            case let .line(cap, dash):
                let pattern = dash.map { String(format: "%.2f", $0) }.joined(separator: "-")
                return "\(group.sourceID).\(tier).line.\(cap.rawValue)" + (dash.isEmpty ? "" : ".\(pattern)")
            }
        }

        private var kindOrder: Int {
            switch kind {
            case .fill: return 0
            case .hatch: return 1
            case .line: return 2
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
            guard let paint = Paint(shape.renderer), paint.strokes || paint.fills || shape.hatch > 0,
                  let feature = feature(for: shape.overlay) else { continue }
            var attributes: [String: Any] = [:]
            if shape.hatch > 0 {
                let key = LayerKey(group: group, tier: shape.tier, kind: .hatch)
                keys.insert(key)
                attributes["hk"] = key.id
                attributes["hatch"] = shape.hatch
            }
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
    private var labelSignature: Int?
    private static let labelSourceID = "aero.airspace.labels"

    nonisolated init() {}

    /// A new style has none of this: everything is drawn again.
    func reset() {
        signatures = [:]
        layers = [:]
        labelSignature = nil
    }

    /// The lowest of these layers: what the charts go under.
    func lowestLayer(in style: MLNStyle) -> MLNStyleLayer? {
        layers.values.flatMap { $0 }.sorted().lazy.compactMap { style.layer(withIdentifier: $0.id) }.first
    }

    /// Where the aircraft is drawn while the follow's drive has the camera, and the time it shows (`glideTick`): the
    /// lines that start at the aircraft start there. Nil otherwise: the aircraft is on its latest fix.
    var aircraftAsDrawn: (coordinate: CLLocationCoordinate2D, time: Date)?

    /// The lines that start at the aircraft, from where it is drawn: the track's end, the line to a diversion field,
    /// the track vector. Each frame of a glide redraws these few points; the rest of the map's lines stay.
    func syncAircraftLines(_ map: AeroMapView, style: MLNStyle, traits: UITraitCollection) {
        syncTrack(map, style: style, traits: traits)
        syncDiversion(map, style: style, traits: traits)
        syncVector(map, style: style, traits: traits)
    }

    /// The line from the aircraft to a diversion field, amber. It started at a fix kept until the aircraft had flown
    /// 150 m (the route was sent again with it): zoomed in, far from the aircraft.
    func syncDiversion(_ map: AeroMapView, style: MLNStyle, traits: UITraitCollection) {
        let ends = Self.diversionLine(from: aircraftAsDrawn?.coordinate ?? map.shownAircraft?.coordinate,
                                      to: map.shownPlan?.diversion?.coordinate)
        sync(.diversion, signature: Self.hash(ends.map { "\($0.latitude),\($0.longitude)" }), on: style, traits: traits) {
            guard ends.count == 2 else { return [] }
            let line = FlightPlanRoutePolyline(coordinates: ends, count: 2)
            line.isDiversion = true
            return [Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType), tier: 0)]
        }
    }

    nonisolated static func diversionLine(from aircraft: CLLocationCoordinate2D?, to field: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D] {
        guard let aircraft, let field else { return [] }
        return [aircraft, field]
    }

    /// Where the track vector drawn starts (nil with none).
    private(set) var vectorOriginDrawn: CLLocationCoordinate2D?

    /// The track vector over its casing, from the aircraft as drawn: it is built from the latest fix, a second's
    /// flight ahead of the aircraft the glide draws, and left a hole between them (the author, 11 Nov). Kept through
    /// a transient empty (a GPS gap, under 5 kt), gone when off.
    func syncVector(_ map: AeroMapView, style: MLNStyle, traits: UITraitCollection) {
        guard map.shownTrackVector else {
            sync(.trackVector, signature: 0, on: style, traits: traits) { [] }
            vectorOriginDrawn = nil
            return
        }
        let vector = map.trackVectorOverlays
        guard !vector.isEmpty else { return }
        let lines = Self.vector(vector, from: aircraftAsDrawn?.coordinate)
        vectorOriginDrawn = lines.first.flatMap { $0.pointCount > 0 ? $0.points()[0].coordinate : nil }
        sync(.trackVector, signature: Self.hash(TrackVectorPolyline.geometry(of: lines)), on: style, traits: traits) {
            lines.map { line in
                Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType),
                      tier: line is TrackVectorCasingPolyline ? 0 : 1)
            }
        }
    }

    /// The track vector's lines moved as one so that the vector starts at `origin` (its first line's first point
    /// there): the ticks keep their one, two and five minutes from the aircraft as drawn. The same lines with no
    /// origin, or already there.
    nonisolated static func vector(_ lines: [MKPolyline], from origin: CLLocationCoordinate2D?) -> [MKPolyline] {
        guard let origin, let first = lines.first, first.pointCount > 0 else { return lines }
        let start = first.points()[0].coordinate
        let (dLat, dLon) = (origin.latitude - start.latitude, origin.longitude - start.longitude)
        guard abs(dLat) > 1e-9 || abs(dLon) > 1e-9 else { return lines }
        return lines.map { line in
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: line.pointCount)
            line.getCoordinates(&coords, range: NSRange(location: 0, length: line.pointCount))
            coords = coords.map { CLLocationCoordinate2D(latitude: $0.latitude + dLat, longitude: $0.longitude + dLon) }
            return line is TrackVectorCasingPolyline ? TrackVectorCasingPolyline(coordinates: coords, count: coords.count)
                : TrackVectorPolyline(coordinates: coords, count: coords.count)
        }
    }

    /// The flown track, in its layer's colour: up to the last whole minute, then its live end, then the line to the
    /// aircraft as drawn. Each frame of a glide redraws only that last line (two points); the rest changes with the
    /// recorded points.
    func syncTrack(_ map: AeroMapView, style: MLNStyle, traits: UITraitCollection) {
        let track = map.shownTrack
        let (history, recorded) = Self.splitTrack(track)
        // Gliding, the aircraft is drawn a moment behind its latest fix: the line stops at the last point it has passed.
        let tail = aircraftAsDrawn.map { drawn in Self.passed(recorded, at: drawn.time) } ?? recorded
        let trackLine = { (points: [CLLocationCoordinate2D]) -> [Shape] in
            guard points.count > 1 else { return [] }
            let line = GPSTrackPolyline(coordinates: points, count: points.count)
            return [Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType), tier: 0)]
        }
        sync(.track, signature: Self.hash(history.count, history.last?.timestamp, map.layerType.rawValue), on: style,
             traits: traits) { trackLine(subsampledTrackCoordinates(Array(history))) }
        sync(.trackTail, signature: Self.hash(tail.count, tail.last?.timestamp, map.layerType.rawValue), on: style,
             traits: traits) { trackLine(subsampledTrackCoordinates(Array(tail))) }
        let end = aircraftAsDrawn?.coordinate ?? map.shownAircraft?.coordinate
        let live = Self.liveEnd(from: tail.last?.coordinate ?? history.last?.coordinate, to: end)
        sync(.trackLive, signature: Self.hash(live.map { "\($0.latitude),\($0.longitude)" }, map.layerType.rawValue),
             on: style, traits: traits) { trackLine(live) }
    }

    /// The recorded points the aircraft has passed at `time`, the first of them always (the cut at the last minute).
    nonisolated static func passed(_ points: ArraySlice<GPSPoint>, at time: Date) -> ArraySlice<GPSPoint> {
        guard let start = points.indices.first else { return points }
        let shown = points.prefix { $0.timestamp <= time }
        return shown.isEmpty ? points[start...start] : shown
    }

    /// The line from the last recorded point to the aircraft: none while they meet (or with no aircraft or no track).
    nonisolated static func liveEnd(from last: CLLocationCoordinate2D?, to aircraft: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D] {
        guard let last, let aircraft,
              abs(last.latitude - aircraft.latitude) > 1e-7 || abs(last.longitude - aircraft.longitude) > 1e-7 else { return [] }
        return [last, aircraft]
    }

    /// Draws `group` from `shapes` (built only when `signature` differs from the last one drawn).
    /// The flown track in two: up to its last whole minute, sent to the map once a minute, and the live end from there
    /// (the cut point in both, so the line is whole). The track was sent whole at each recorded point, up to 3,000
    /// vertices, and past them the subsampling moved the whole line each time. (6.10.0)
    nonisolated static func splitTrack(_ track: [GPSPoint]) -> (history: ArraySlice<GPSPoint>, tail: ArraySlice<GPSPoint>) {
        guard let last = track.last else { return ([], []) }
        let minute = (last.timestamp.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let cut = track.lastIndex { $0.timestamp.timeIntervalSinceReferenceDate <= minute } ?? 0
        return (track[...cut], track[cut...])
    }

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
            } else if let labels = style.layer(withIdentifier: Self.labelSourceID) {
                // The boundary labels stay on top, or the lines they mask run through them.
                style.insertLayer(layer, below: labels)
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
        case .hatch:
            let layer = MLNFillStyleLayer(identifier: key.id, source: source)
            layer.predicate = NSPredicate(format: "hk == %@", key.id)
            layer.fillPattern = NSExpression(forConstantValue: PilotMapStyle.hatchImageName)
            layer.fillOpacity = NSExpression(mglJSONObject: ["get", "hatch"])
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
        sync(.airspace, signature: Self.hash(airspace.map { "\($0.airspaceId).\($0.tier.rawValue)" }, selected), on: style,
             traits: traits) {
            airspace.map { polygon in
                let renderer = MKPolygonRenderer(polygon: polygon)
                let isSelected = polygon.airspaceId == selected
                polygon.style(renderer, selected: isSelected)
                return Shape(overlay: polygon, renderer: renderer, tier: isSelected ? 1 : 0,
                             hatch: polygon.hatchAlpha(selected: isSelected))
            }
        }

        syncLabels(map.shownAirspaceLabels ? airspace : [], on: style)

        // The NOTAM areas: a dashed circle each, over the airspace and under everything the pilot flies by.
        let notams = map.shownNotams
        sync(.notams, signature: Self.hash(notams.map(\.id)), on: style, traits: traits) {
            notams.compactMap { item in
                guard case .area(let radius) = item.shape else { return nil }
                var ring = NotamMapContent.ring(centre: item.coordinate, radiusNm: radius)
                let line = MKPolyline(coordinates: &ring, count: ring.count)
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NotamMapStyle.color
                renderer.lineWidth = 2.5
                renderer.lineDashPattern = AirspaceMapKind.notam.dash.map { NSNumber(value: $0) }
                renderer.lineCap = .butt
                return Shape(overlay: line, renderer: renderer, tier: 0)
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

        syncTrack(map, style: style, traits: traits)

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

        // The route: flown dimmed, the rest bright (dimmed too while diverting).
        let plan = map.shownPlan
        let routeSignature = Self.hash(plan?.waypoints.map { "\($0.latitude),\($0.longitude)" }, plan?.currentWaypointIndex,
                                       plan?.diversion?.ident)
        sync(.route, signature: routeSignature, on: style, traits: traits) {
            guard let plan else { return [] }
            return AeroMapView.routePolylines(for: plan).enumerated().map { tier, line in
                Shape(overlay: line, renderer: AeroMapView.lineRenderer(for: line, layerType: map.layerType), tier: tier)
            }
        }

        syncDiversion(map, style: style, traits: traits)
        syncVector(map, style: style, traits: traits)
    }

    /// The limits along the airspace's boundaries: one text layer over one source of closed lines. (6.9.0)
    private func syncLabels(_ airspace: [AirspacePolygon], on style: MLNStyle) {
        let signature = Self.hash(airspace.map(\.airspaceId), airspace.map(\.boundaryText))
        guard labelSignature != signature else { return }
        labelSignature = signature
        var features: [MLNPolylineFeature] = []
        for polygon in airspace {
            var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polygon.pointCount)
            polygon.getCoordinates(&coords, range: NSRange(location: 0, length: polygon.pointCount))
            guard let first = coords.first else { continue }
            coords.append(first)
            let line = MLNPolylineFeature(coordinates: coords, count: UInt(coords.count))
            let c = polygon.mapKind.color
            line.attributes = ["text": polygon.boundaryText,
                               "color": Self.css(UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1), traits: .current)]
            features.append(line)
        }
        let source: MLNShapeSource
        if let existing = style.source(withIdentifier: Self.labelSourceID) as? MLNShapeSource {
            source = existing
        } else {
            source = MLNShapeSource(identifier: Self.labelSourceID, shape: nil, options: nil)
            style.addSource(source)
        }
        source.shape = MLNShapeCollectionFeature(shapes: features)
        guard style.layer(withIdentifier: Self.labelSourceID) == nil else { return }
        let layer = MLNSymbolStyleLayer(identifier: Self.labelSourceID, source: source)
        layer.text = NSExpression(mglJSONObject: ["get", "text"])
        layer.textFontNames = NSExpression(forConstantValue: ["B612 Bold"])
        layer.textFontSize = NSExpression(forConstantValue: 15)
        layer.textColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
        layer.textHaloColor = NSExpression(forConstantValue: UIColor.white)
        layer.textHaloWidth = NSExpression(forConstantValue: 2.4)
        layer.symbolPlacement = NSExpression(forConstantValue: "line")
        layer.symbolSpacing = NSExpression(forConstantValue: 260)
        style.addLayer(layer)
    }

    /// The map's zoom as `VFRMapLayer` sizes its arrowheads and dashes: metres per point at the map's middle.
    static func vfrZoom(of mapView: MLNMapView) -> VFRMapLayer.Zoom? {
        guard mapView.bounds.width > 0 else { return nil }
        let metersPerPoint = mapView.metersPerPoint(atLatitude: mapView.centerCoordinate.latitude)
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return nil }
        return VFRMapLayer.Zoom(metersPerPoint: metersPerPoint)
    }

    static func hash(_ values: AnyHashable?...) -> Int {
        var hasher = Hasher()
        for value in values { hasher.combine(value) }
        return hasher.finalize()
    }
}
