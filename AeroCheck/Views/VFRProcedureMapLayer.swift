import MapKit
import UIKit

// MARK: - Aerodrome procedures on the map (6.2.0)
//
// The traffic circuits, VFR arrival and departure routes and their sectors from open flightmaps
// (`OFMDataService`), drawn on the three maps that plan and fly a route: Plan › Map and the Cockpit's MAP
// (both representables in `NavigationView.swift`) and the route builder. One implementation serves all
// three, so the copies can't drift the way the airspace diff once did.
//
// - What is drawn: the map view builds a `VFRMapContent` when its region moves (never on a GPS tick),
//   gated by the visible span and capped; the representables hand it to `VFRMapLayer.sync`, which returns
//   at once while the content's signature is unchanged and otherwise adds and removes overlays by id.
// - How: dedicated overlay classes (`VFRCircuitOverlay`, `VFRRouteOverlay`, `VFRDashOverlay`,
//   `VFRSectorOverlay`), never a bare `MKPolyline`, because every map has a generic `MKPolyline` branch
//   in its renderer and the builder used to remove every `MKPolyline` when it redrew its route. They are
//   inserted below the route, the track and the track vector; the aircraft is an annotation, always on
//   top. They are drawn by MapKit's own renderers, which draw vectors: a renderer that draws its own
//   tiles, or one with a dash pattern, is rasterized and magnified past MapKit's last tile level (lines
//   twice as thick on a phone at 2 NM). So dashes are cut into segments, and arrowheads drawn as
//   chevrons, at the map's zoom, and cut again when it changes.
// - Labels are bitmap annotations (the `aeroMarkerSymbol` rule: a symbol image renders black on iOS 26),
//   at least 44 pt square, and their callout says where the data comes from, and offers the error report.
//
// The data is indicative: open flightmaps is a community source, and the callout says to check the
// official chart. Everything is off by default.

// MARK: - Which procedures

/// The three switches (Map sheet, Navigation & Maps, the builder's layers menu) as one filter.
struct VFRLayerSelection: Hashable, Sendable {
    /// Powered traffic circuits (plain, and the heavy / multi-engine / retractable variants).
    var circuits: Bool
    /// Powered VFR arrival and departure routes, with their sectors.
    var routes: Bool
    /// Glider, UL, gyro and helicopter circuits; with `routes`, the helicopter routes too.
    var nonPowered: Bool

    init(circuits: Bool, routes: Bool, nonPowered: Bool) {
        self.circuits = circuits
        self.routes = routes
        self.nonPowered = nonPowered
    }

    init(settings: AppSettings) {
        self.init(circuits: settings.showVFRCircuitsOnMap, routes: settings.showVFRRoutesOnMap,
                  nonPowered: settings.showNonPoweredCircuitsOnMap)
    }

    var isAnyOn: Bool { circuits || routes || nonPowered }

    /// What an aeroplane with an engine flies: the plain procedure and its heavy variant.
    static let poweredCategories: Set<VFRProcedure.Category> = [.powered, .heavy]

    /// Whether the map shows `procedure`. Each switch is a set of procedures, so the third one works on
    /// its own: a glider pilot can show the glider circuits without the powered ones.
    func includes(_ procedure: VFRProcedure) -> Bool {
        let powered = procedure.isFor(any: Self.poweredCategories)
        switch procedure.kind {
        case .circuit: return powered ? circuits : nonPowered
        case .arrival, .departure: return routes && (powered || nonPowered)
        }
    }
}

// MARK: - Density

/// How much of it the map shows at once: nothing past 40 NM across, no labels past 20 NM, at most 80
/// procedures, the flight's destination and departure first. A circuit is about 3 NM across: zoomed out
/// further, they would only cover the chart and its airspace.
enum VFRMapDensity {
    static let procedureSpanLimitNM: Double = 40
    static let labelSpanLimitNM: Double = 20
    static let procedureLimit = 80

    /// The visible span in NM: the shorter side of the region (on an iPad in portrait, the width).
    /// The longer side is what the zoom range of the ICAO chart can't bring under 20 NM.
    static func spanNM(of region: MKCoordinateRegion) -> Double {
        let latitudeNM = abs(region.span.latitudeDelta) * 60
        let longitudeNM = abs(region.span.longitudeDelta) * 60 * cos(region.center.latitude * .pi / 180)
        return min(latitudeNM, longitudeNM)
    }

    static func showsProcedures(in region: MKCoordinateRegion) -> Bool {
        spanNM(of: region) <= procedureSpanLimitNM
    }

    static func showsLabels(in region: MKCoordinateRegion) -> Bool {
        spanNM(of: region) <= labelSpanLimitNM
    }

    /// `procedures` in drawing priority, at most `limit`: those of `firstAerodromes` in that order (the
    /// destination, then the departure), then the rest by distance from `center`.
    static func prioritized(_ procedures: [VFRProcedure], around center: CLLocationCoordinate2D,
                            first firstAerodromes: [String], limit: Int = procedureLimit) -> [VFRProcedure] {
        let rank = Dictionary(firstAerodromes.map { $0.uppercased() }.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        let cosLat = cos(center.latitude * .pi / 180)
        func distance(_ procedure: VFRProcedure) -> Double {
            let b = procedure.bounds
            let lat = (b.minLatitude + b.maxLatitude) / 2 - center.latitude
            let lon = ((b.minLongitude + b.maxLongitude) / 2 - center.longitude) * cosLat
            return lat * lat + lon * lon
        }
        let ordered = procedures.enumerated().sorted { a, b in
            let ra = rank[a.element.aerodrome.uppercased()] ?? Int.max
            let rb = rank[b.element.aerodrome.uppercased()] ?? Int.max
            if ra != rb { return ra < rb }
            let da = distance(a.element), db = distance(b.element)
            if da != db { return da < db }
            return a.offset < b.offset
        }
        return ordered.prefix(max(0, limit)).map(\.element)
    }

    /// The aerodrome codes of a plan's destination, then its departure, for `prioritized`.
    static func endpointAerodromes(of plan: FlightPlan?) -> [String] {
        guard let plan, let first = plan.waypoints.first, let last = plan.waypoints.last else { return [] }
        return [last, first].compactMap(aerodromeCode).reduce(into: []) { codes, code in
            if !codes.contains(code) { codes.append(code) }
        }
    }

    private static func aerodromeCode(_ waypoint: FlightPlanWaypoint) -> String? {
        if waypoint.pointKind == .aerodrome, let id = waypoint.sourceId, !id.isEmpty { return id.uppercased() }
        let name = waypoint.name.trimmingCharacters(in: .whitespaces).uppercased()
        let looksLikeICAO = name.count == 4 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return looksLikeICAO ? name : nil
    }
}

// MARK: - Where the label goes, and which way the arrow points

enum VFRLabelPlacement {
    /// A circuit's label: the vertex farthest from where the line starts (the runway), which is on the
    /// downwind. Schema v1 publishes no label position of its own.
    static func circuitAnchor(_ line: [VFRCoordinate]) -> VFRCoordinate {
        guard let start = line.first else { return VFRCoordinate(latitude: 0, longitude: 0) }
        return line.max { flatDistance(start, $0) < flatDistance(start, $1) } ?? start
    }

    /// A route's label: halfway along the line.
    static func midLine(_ line: [VFRCoordinate]) -> VFRCoordinate {
        guard line.count > 1 else { return line.first ?? VFRCoordinate(latitude: 0, longitude: 0) }
        let legs = zip(line, line.dropFirst()).map { flatDistance($0, $1) }
        var remaining = legs.reduce(0, +) / 2
        for (index, length) in legs.enumerated() {
            if remaining <= length, length > 0 {
                let t = remaining / length
                let a = line[index], b = line[index + 1]
                return VFRCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                     longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            remaining -= length
        }
        return line[line.count - 1]
    }

    /// Distance on a local flat projection, in degrees of latitude: enough to compare a few NM.
    static func flatDistance(_ a: VFRCoordinate, _ b: VFRCoordinate) -> Double {
        let cosLat = cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let dLat = b.latitude - a.latitude
        let dLon = (b.longitude - a.longitude) * cosLat
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}

/// Where a route's arrowhead is drawn: at the end of the line toward the field for an arrival, at the
/// end away from it for a departure. Arrivals in the files all end at the field; departures go either
/// way (in 2610, 41 of Switzerland's start at the field and 16 end there), so the field decides.
enum VFRArrow: String, Hashable, Sendable {
    case none
    /// At the line's last point, along its last segment.
    case atEnd
    /// At the line's first point, pointing back along its first segment.
    case atStart

    static func arrow(for procedure: VFRProcedure, field: CLLocationCoordinate2D?) -> VFRArrow {
        guard procedure.kind != .circuit, let first = procedure.line.first, let last = procedure.line.last else {
            return .none
        }
        // Without the field, the line's own direction (true of every arrival, and most departures).
        guard let field else { return .atEnd }
        let fieldPoint = VFRCoordinate(latitude: field.latitude, longitude: field.longitude)
        let lastIsNearer = VFRLabelPlacement.flatDistance(last, fieldPoint) <= VFRLabelPlacement.flatDistance(first, fieldPoint)
        switch procedure.kind {
        case .arrival: return lastIsNearer ? .atEnd : .atStart
        case .departure: return lastIsNearer ? .atStart : .atEnd
        case .circuit: return .none
        }
    }
}

// MARK: - What the map draws

/// One procedure as the map draws it, with what its callout and error report need.
struct VFRMapItem: Identifiable, Equatable {
    let procedure: VFRProcedure
    let arrow: VFRArrow
    /// "2900 ft", "Alt: see chart", or a route's name.
    let labelText: String
    let labelAnchor: VFRCoordinate
    /// The country of the file it came from (its id's prefix).
    let country: String
    /// OFM's region of that country (`LSAS`), and the cycle on disk.
    let region: String?
    let airac: String?

    var id: String { procedure.id }
    /// Changes when the shape would be drawn differently.
    var drawKey: String { "\(procedure.id)|\(arrow.rawValue)" }
    /// Changes when the label or its callout would read differently.
    var labelKey: String { "\(procedure.id)|\(labelText)|\(airac ?? "")" }

    static func country(ofProcedureId id: String) -> String {
        String(id.prefix { $0 != ":" })
    }

    static func labelText(for procedure: VFRProcedure) -> String {
        switch procedure.kind {
        case .circuit:
            return procedure.altitudeFt.map { "\($0) ft" } ?? L10n.VFRMap.altitudeSeeChart
        case .arrival, .departure:
            return procedure.name.isEmpty ? VFRMapStrings.kindName(procedure.kind) : procedure.name
        }
    }
}

/// What a map shows of the procedures for its region, and the palette to draw it in. Built when the
/// region or the switches change; `signature` lets the representables skip the diff on every GPS tick.
struct VFRMapContent: Equatable {
    let items: [VFRMapItem]
    let showsLabels: Bool
    let palette: VFRMapPalette
    let signature: Int

    static func empty(_ palette: VFRMapPalette = .day) -> VFRMapContent {
        VFRMapContent(items: [], showsLabels: false, palette: palette)
    }

    init(items: [VFRMapItem], showsLabels: Bool, palette: VFRMapPalette) {
        self.items = items
        self.showsLabels = showsLabels
        self.palette = palette
        // Order-free: the same procedures in another order (the aircraft moved, and the nearest changed)
        // draw the same map.
        var hasher = Hasher()
        hasher.combine(palette)
        hasher.combine(showsLabels)
        hasher.combine(items.map(\.drawKey).sorted())
        if showsLabels { hasher.combine(items.map(\.labelKey).sorted()) }
        signature = hasher.finalize()
    }

    static func == (lhs: VFRMapContent, rhs: VFRMapContent) -> Bool { lhs.signature == rhs.signature }

    /// - Parameters:
    ///   - candidates: the procedures in or near `region` (`OFMDataService.procedures(in:)`).
    ///   - firstAerodromes: drawn first, in that order (`VFRMapDensity.endpointAerodromes(of:)`).
    ///   - fieldPosition: an aerodrome's position, for the departures' arrowheads.
    ///   - cycle: the AIRAC and OFM region of a country's data on disk.
    static func make(candidates: [VFRProcedure], region: MKCoordinateRegion, selection: VFRLayerSelection,
                     palette: VFRMapPalette, firstAerodromes: [String] = [],
                     fieldPosition: (String) -> CLLocationCoordinate2D? = { _ in nil },
                     cycle: (String) -> (airac: String?, region: String?) = { _ in (nil, nil) }) -> VFRMapContent {
        guard selection.isAnyOn, VFRMapDensity.showsProcedures(in: region) else { return .empty(palette) }
        let chosen = VFRMapDensity.prioritized(candidates.filter(selection.includes), around: region.center,
                                               first: firstAerodromes)
        let items = chosen.map { procedure -> VFRMapItem in
            let country = VFRMapItem.country(ofProcedureId: procedure.id)
            let info = cycle(country)
            let anchor = procedure.kind == .circuit
                ? VFRLabelPlacement.circuitAnchor(procedure.line) : VFRLabelPlacement.midLine(procedure.line)
            let field = procedure.kind == .departure || procedure.kind == .arrival ? fieldPosition(procedure.aerodrome) : nil
            return VFRMapItem(procedure: procedure, arrow: VFRArrow.arrow(for: procedure, field: field),
                              labelText: VFRMapItem.labelText(for: procedure), labelAnchor: anchor,
                              country: country, region: info.region, airac: info.airac)
        }
        return VFRMapContent(items: items, showsLabels: VFRMapDensity.showsLabels(in: region), palette: palette)
    }
}

// MARK: - Palette

/// The colours of the procedures. Blue, the ICAO and open flightmaps colour for traffic circuits, kept
/// apart from what is blue already: a dark ink blue (#0D339E) with a white casing, against the chart's
/// lighter cerulean CTR bands and the airspace overlay's mid blue (0.2, 0.4, 0.9) drawn 1.5 pt with a
/// fill. Not magenta (the route), cyan (what can be touched), amber or red (cautions and warnings).
///
/// The map delegates can't read SwiftUI's environment, so the map views pass the palette for the
/// cockpit theme. At night the casing goes dark and the blue lighter and duller, so nothing on the map
/// glows white.
enum VFRMapPalette: String, Hashable, Sendable {
    case day, night

    init(theme: CockpitTheme) {
        self = theme.mode == .night ? .night : .day
    }

    var procedure: UIColor {
        switch self {
        case .day: return UIColor(red: 0.05, green: 0.20, blue: 0.62, alpha: 1)
        case .night: return UIColor(red: 0.36, green: 0.44, blue: 0.78, alpha: 1)
        }
    }

    var casing: UIColor {
        switch self {
        case .day: return UIColor.white.withAlphaComponent(0.92)
        case .night: return UIColor.black.withAlphaComponent(0.6)
        }
    }

    var sectorFill: UIColor { procedure.withAlphaComponent(0.08) }
    var sectorStroke: UIColor { procedure.withAlphaComponent(0.85) }

    /// Austrian noise-abatement areas: grey, not a procedure to fly.
    var noise: UIColor {
        switch self {
        case .day: return UIColor(white: 0.38, alpha: 0.9)
        case .night: return UIColor(white: 0.55, alpha: 0.8)
        }
    }

    var labelFill: UIColor {
        switch self {
        case .day: return UIColor.white.withAlphaComponent(0.94)
        case .night: return UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 0.92)
        }
    }

    /// What can be touched in the callout: the cockpit theme's `action` (cyan by day, the night's red).
    var action: UIColor {
        switch self {
        case .day: return UIColor(red: 0.24, green: 0.78, blue: 0.93, alpha: 1)
        case .night: return UIColor(red: 0.78, green: 0.28, blue: 0.16, alpha: 1)
        }
    }

    var labelText: UIColor {
        switch self {
        case .day: return UIColor(red: 0.03, green: 0.10, blue: 0.36, alpha: 1)
        case .night: return UIColor(red: 0.68, green: 0.73, blue: 0.94, alpha: 1)
        }
    }
}

// MARK: - Overlays

/// A shape of a procedure on the map: a stroke of its line, one of its sectors, or its arrowhead.
protocol VFRProcedureShape: AnyObject {
    var procedureId: String { get }
    /// `VFRMapItem.drawKey` of the item it was built from.
    var drawKey: String { get }
    /// Built for the map's zoom (dashes, ticks, arrowheads): redrawn when it changes.
    var isScaled: Bool { get }
}

/// Which stroke of a line an overlay is. MapKit gives an overlay one renderer, and its renderers draw
/// one stroke each: a cased line is two overlays, the casing under the core, as the track vector's is.
enum VFRStroke: Hashable, Sendable {
    case casing
    case core
}

/// A traffic circuit's solid line (its casing, or its core): the powered circuits.
final class VFRCircuitOverlay: MKPolyline, VFRProcedureShape {
    var procedureId = ""
    var drawKey = ""
    var stroke: VFRStroke = .core
    var categories: Set<VFRProcedure.Category> = [.powered]
    var isApproximate = false
    var isScaled: Bool { false }
}

/// A VFR arrival or departure route's arrowhead: a chevron at the end of its line (casing, or core),
/// 12 pt long at the zoom it was built for.
final class VFRRouteOverlay: MKPolyline, VFRProcedureShape {
    var procedureId = ""
    var drawKey = ""
    var stroke: VFRStroke = .core
    var kind: VFRProcedure.Kind = .arrival
    var categories: Set<VFRProcedure.Category> = [.powered]
    var isApproximate = false
    var isArrowhead: Bool { true }
    var isScaled: Bool { true }
}

/// Every dashed or dotted line, as its dashes: a route's line, a glider, UL or helicopter circuit, a
/// sector's outline, the ticks of a noise-abatement area's hatch. MapKit draws a renderer's
/// `lineDashPattern` by rasterizing, and past its last tile level the dashes grew with the zoom (two
/// and a half times on a phone at 2 NM); dashes cut into segments at the map's zoom stay vectors, the
/// same size at every zoom, and are cut again when the zoom changes.
final class VFRDashOverlay: MKMultiPolyline, VFRProcedureShape {
    enum Role: Hashable, Sendable {
        case circuit
        case route
        case sectorOutline
        case hatch
    }

    var procedureId = ""
    var drawKey = ""
    var role: Role = .route
    var stroke: VFRStroke = .core
    var style = VFRLineStyle(coreWidth: 2, casingWidth: 5, dash: [], isDotted: false, alpha: 1)
    var isScaled: Bool { true }
}

/// A sector drawn with a route: an arrival corridor or an area (its 8 % fill; the dashed outline is a
/// `VFRDashOverlay`), or an Austrian noise-abatement area (its thin outline; the hatch is ticks).
final class VFRSectorOverlay: MKPolygon, VFRProcedureShape {
    var procedureId = ""
    var drawKey = ""
    var areaKind: VFRArea.Kind = .corridor
    var isScaled: Bool { false }
}

// MARK: - Styles and renderers

/// How a procedure's line is stroked, in screen points.
struct VFRLineStyle: Equatable {
    var coreWidth: CGFloat
    var casingWidth: CGFloat
    /// Empty for a solid line.
    var dash: [CGFloat]
    /// Round dots rather than dashes (helicopters).
    var isDotted: Bool
    var alpha: CGFloat

    /// Circuits solid 3 pt with a casing; glider, UL and gyro dashed, helicopters dotted; routes dashed
    /// 2 pt; a shape drawn from OFM's straight skeleton (`approx`) thinner and lighter.
    static func style(kind: VFRProcedure.Kind, categories: Set<VFRProcedure.Category>,
                      approximate: Bool) -> VFRLineStyle {
        let isCircuit = kind == .circuit
        let heli = categories.contains(.helicopter)
        let powered = !categories.isDisjoint(with: VFRLayerSelection.poweredCategories)
        var style = VFRLineStyle(coreWidth: isCircuit ? 3 : 2, casingWidth: 0, dash: [], isDotted: false, alpha: 1)
        if heli {
            style.dash = [0.01, 7]
            style.isDotted = true
        } else if !isCircuit {
            style.dash = [10, 6]
        } else if !powered {
            style.dash = [9, 6]
        }
        if approximate {
            style.coreWidth -= 1
            style.alpha = 0.6
        }
        style.casingWidth = style.coreWidth + 3
        return style
    }

    /// A sector's outline: 1.5 pt, dashed 6 on 4.
    static let sectorOutline = VFRLineStyle(coreWidth: 1.5, casingWidth: 0, dash: [6, 4], isDotted: false, alpha: 1)
    /// A noise-abatement area's hatch ticks.
    static let hatch = VFRLineStyle(coreWidth: 1.2, casingWidth: 0, dash: [], isDotted: false, alpha: 1)

    /// An arrowhead's chevron: solid, a little heavier than its line so it reads at a glance.
    var arrowhead: VFRLineStyle {
        VFRLineStyle(coreWidth: coreWidth + 0.5, casingWidth: coreWidth + 3.5, dash: [], isDotted: false, alpha: alpha)
    }
}

// MARK: - Label annotation

/// A procedure's label on the map ("2900 ft", "ARR SECTOR EAST"), and the way to its callout.
final class VFRProcedureAnnotation: NSObject, MKAnnotation {
    let item: VFRMapItem
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(item: VFRMapItem) {
        self.item = item
        coordinate = item.labelAnchor.coordinate
        title = item.procedure.name.isEmpty ? VFRMapStrings.kindName(item.procedure.kind) : item.procedure.name
        super.init()
    }

    var labelKey: String { item.labelKey }
}

/// The label as a bitmap: a rounded box, the procedure's colour around it, in a transparent square of
/// at least 44 pt so it is easy to tap. A bitmap, never a symbol image (`aeroMarkerSymbol`).
enum VFRProcedureLabelImage {
    private static var cache: [String: UIImage] = [:]

    /// A circuit's altitude is read in flight: the kneeboard label size. A route's name is smaller.
    static func fontSize(for kind: VFRProcedure.Kind) -> CGFloat {
        kind == .circuit ? CockpitType.label : CockpitType.size(kneeboard: 16, phone: 14)
    }

    static func image(text: String, kind: VFRProcedure.Kind, palette: VFRMapPalette) -> UIImage {
        let size = fontSize(for: kind)
        let key = "\(text)|\(kind.rawValue)|\(palette.rawValue)|\(size)"
        if let cached = cache[key] { return cached }
        let font = UIFont.aero(size: size, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.labelText]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let box = CGSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 6)
        let canvas = CGSize(width: max(44, box.width + 4), height: max(44, box.height + 4))
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            let rect = CGRect(x: (canvas.width - box.width) / 2, y: (canvas.height - box.height) / 2,
                              width: box.width, height: box.height)
            let shape = UIBezierPath(roundedRect: rect, cornerRadius: 7)
            palette.labelFill.setFill()
            shape.fill()
            palette.procedure.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: attributes)
        }
        cache[key] = image
        return image
    }
}

// MARK: - The layer on a map

/// Keeps a map's procedures in step with a `VFRMapContent`. Shared by the three maps.
@MainActor
enum VFRMapLayer {
    /// What a map's coordinator remembers between updates. A class, not a struct passed `inout`:
    /// adding an overlay makes MapKit ask the coordinator for its renderer there and then, and the
    /// renderer reads `palette`, which an `inout` access held over the whole sync would make an
    /// exclusivity violation (a crash, the first time a map in a window drew a procedure).
    final class State {
        /// The content last drawn; nil before the first.
        var signature: Int?
        /// The palette the renderers and labels on the map were made with.
        var palette: VFRMapPalette = .day
        /// The zoom the arrowheads were sized for.
        var zoom: Zoom?

        init() {}
    }

    /// The map's zoom in half steps, which is what the arrowheads are sized for: they are drawn in map
    /// coordinates, so a pinch scales them until the next update brings them back to 12 pt.
    struct Zoom: Equatable {
        let metersPerPoint: Double
        var step: Int { Int((log2(max(metersPerPoint, 0.01)) * 2).rounded()) }
        static func == (lhs: Zoom, rhs: Zoom) -> Bool { lhs.step == rhs.step }

        init(metersPerPoint: Double) { self.metersPerPoint = metersPerPoint }

        /// Across the middle of the map, so turning it (track up) doesn't change it. Nil until the map
        /// has a size.
        @MainActor
        init?(mapView: MKMapView) {
            let bounds = mapView.bounds
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let left = mapView.convert(CGPoint(x: bounds.minX, y: bounds.midY), toCoordinateFrom: mapView)
            let right = mapView.convert(CGPoint(x: bounds.maxX, y: bounds.midY), toCoordinateFrom: mapView)
            guard CLLocationCoordinate2DIsValid(left), CLLocationCoordinate2DIsValid(right) else { return nil }
            let meters = MKMapPoint(left).distance(to: MKMapPoint(right))
            guard meters > 0, meters.isFinite else { return nil }
            self.init(metersPerPoint: meters / Double(bounds.width))
        }
    }

    /// An arrowhead's length on screen.
    static let arrowheadPoints: Double = 12

    /// The route and the flight's lines, which the procedures stay under: the nav maps' route, diversion
    /// line, track and track vector, and the builder's route, its casing and the selected leg's halo.
    static func isRouteOverlay(_ overlay: MKOverlay) -> Bool {
        overlay is FlightPlanRoutePolyline || overlay is GPSTrackPolyline || overlay is TrackVectorPolyline
            || overlay is RouteLinePolyline || overlay is RouteCasingPolyline || overlay is SelectedLegPolyline
    }

    /// Bring `mapView` to `content`: nothing while its signature is the one drawn and the zoom is the
    /// same (every GPS tick), otherwise remove what went and add what came, by id. A new palette
    /// redraws everything; a new zoom, what is built for it (dashes, ticks, arrowheads).
    static func sync(_ content: VFRMapContent, on mapView: MKMapView, state: State) {
        let zoom = Zoom(mapView: mapView)
        let contentChanged = state.signature != content.signature
        let zoomChanged = state.zoom != zoom
        guard contentChanged || zoomChanged else { return }
        let paletteChanged = state.palette != content.palette
        state.palette = content.palette
        state.signature = content.signature
        state.zoom = zoom

        func key(_ overlay: MKOverlay) -> String { (overlay as? VFRProcedureShape)?.drawKey ?? "" }
        let shapes = mapView.overlays.filter { $0 is VFRProcedureShape }
        let scaled = shapes.filter { ($0 as? VFRProcedureShape)?.isScaled == true }
        let fixed = shapes.filter { ($0 as? VFRProcedureShape)?.isScaled != true }
        let wanted = Set(content.items.map(\.drawKey))
        let staleFixed = fixed.filter { paletteChanged || !wanted.contains(key($0)) }
        // What is built for the zoom, all again for a new zoom or palette; otherwise what went.
        let staleScaled = zoomChanged || paletteChanged ? scaled : scaled.filter { !wanted.contains(key($0)) }
        let stale = staleFixed + staleScaled
        if !stale.isEmpty { mapView.removeOverlays(stale) }

        let fixedDrawn = Set(fixed.map(key)).subtracting(staleFixed.map(key))
        let scaledDrawn = Set(scaled.map(key)).subtracting(staleScaled.map(key))
        for item in content.items {
            if !fixedDrawn.contains(item.drawKey) {
                for overlay in overlays(for: item) { insert(overlay, on: mapView) }
            }
            if let zoom, !scaledDrawn.contains(item.drawKey) {
                for overlay in scaledOverlays(for: item, zoom: zoom) { insert(overlay, on: mapView) }
            }
        }

        guard contentChanged else { return }
        let labels = mapView.annotations.compactMap { $0 as? VFRProcedureAnnotation }
        let wantedLabels = content.showsLabels ? Set(content.items.map(\.labelKey)) : []
        let staleLabels = labels.filter { paletteChanged || !wantedLabels.contains($0.labelKey) }
        if !staleLabels.isEmpty { mapView.removeAnnotations(staleLabels) }
        let shown = Set(labels.map(\.labelKey)).subtracting(staleLabels.map(\.labelKey))
        if content.showsLabels {
            let added = content.items.filter { !shown.contains($0.labelKey) }.map(VFRProcedureAnnotation.init)
            if !added.isEmpty { mapView.addAnnotations(added) }
        }
    }

    /// What doesn't depend on the zoom: the sectors' fills and the noise areas' outlines, and a solid
    /// circuit's casing and core.
    static func overlays(for item: VFRMapItem) -> [MKOverlay] {
        let procedure = item.procedure
        var overlays: [MKOverlay] = procedure.areas.map { area in
            let ring = area.polygon.map(\.coordinate)
            let sector = VFRSectorOverlay(coordinates: ring, count: ring.count)
            sector.procedureId = procedure.id
            sector.drawKey = item.drawKey
            sector.areaKind = area.kind
            return sector
        }
        let style = VFRLineStyle.style(kind: procedure.kind, categories: procedure.categories,
                                       approximate: procedure.isApproximate)
        if procedure.kind == .circuit, style.dash.isEmpty {
            let line = procedure.line.map(\.coordinate)
            for stroke in [VFRStroke.casing, .core] {
                let circuit = VFRCircuitOverlay(coordinates: line, count: line.count)
                circuit.procedureId = procedure.id
                circuit.drawKey = item.drawKey
                circuit.stroke = stroke
                circuit.categories = procedure.categories
                circuit.isApproximate = procedure.isApproximate
                overlays.append(circuit)
            }
        }
        return overlays
    }

    /// What is built for the zoom: the dashes of a dashed line (casing and core), a sector's dashed
    /// outline, a noise area's hatch ticks, a route's arrowhead.
    static func scaledOverlays(for item: VFRMapItem, zoom: Zoom) -> [MKOverlay] {
        let procedure = item.procedure
        var overlays: [MKOverlay] = []
        func dashOverlay(_ pieces: [[CLLocationCoordinate2D]], role: VFRDashOverlay.Role, stroke: VFRStroke,
                         style: VFRLineStyle) -> VFRDashOverlay? {
            guard !pieces.isEmpty else { return nil }
            let overlay = VFRDashOverlay(pieces.map { MKPolyline(coordinates: $0, count: $0.count) })
            overlay.procedureId = procedure.id
            overlay.drawKey = item.drawKey
            overlay.role = role
            overlay.stroke = stroke
            overlay.style = style
            return overlay
        }
        for area in procedure.areas {
            let ring = area.polygon.map(\.coordinate)
            if area.kind == .noise {
                let ticks = hatchTicks(around: ring, zoom: zoom)
                if let hatch = dashOverlay(ticks, role: .hatch, stroke: .core, style: VFRLineStyle.hatch) {
                    overlays.append(hatch)
                }
            } else {
                let outline = dashes(along: ring + ring.prefix(1), pattern: VFRLineStyle.sectorOutline.dash, zoom: zoom)
                if let dashed = dashOverlay(outline, role: .sectorOutline, stroke: .core, style: VFRLineStyle.sectorOutline) {
                    overlays.append(dashed)
                }
            }
        }
        let style = VFRLineStyle.style(kind: procedure.kind, categories: procedure.categories,
                                       approximate: procedure.isApproximate)
        if !style.dash.isEmpty {
            let pieces = dashes(along: procedure.line.map(\.coordinate), pattern: style.dash, zoom: zoom)
            let role: VFRDashOverlay.Role = procedure.kind == .circuit ? .circuit : .route
            for stroke in [VFRStroke.casing, .core] {
                if let dashed = dashOverlay(pieces, role: role, stroke: stroke, style: style) { overlays.append(dashed) }
            }
        }
        overlays += arrowheadOverlays(for: item, zoom: zoom)
        return overlays
    }

    /// `coordinates` cut into dashes of `pattern` (on, off, … in points) at `zoom`, the pattern running
    /// on round the corners. A dash shorter than a point (a dot) is kept a point long, for its round
    /// caps to draw.
    static func dashes(along coordinates: [CLLocationCoordinate2D], pattern: [CGFloat],
                       zoom: Zoom) -> [[CLLocationCoordinate2D]] {
        guard coordinates.count >= 2, !pattern.isEmpty, let first = coordinates.first else { return [] }
        let perPoint = zoom.metersPerPoint * MKMapPointsPerMeterAtLatitude(first.latitude)
        let lengths = pattern.map { max(Double($0), 0.5) * perPoint }
        guard lengths.allSatisfy({ $0 > 0 && $0.isFinite }) else { return [] }
        let points = coordinates.map(MKMapPoint.init)
        var pieces: [[CLLocationCoordinate2D]] = []
        var current: [MKMapPoint] = [points[0]]
        var index = 0                      // into `lengths`: even = dash, odd = gap
        var remaining = lengths[0]
        // A runaway pattern on a long line at the closest zoom stays bounded.
        let budget = 4_000
        for (a, b) in zip(points, points.dropFirst()) {
            var start = a
            // In map points, as the pattern is (`MKMapPoint.distance(to:)` is in metres).
            var segment = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            let total = segment
            while segment > 0, pieces.count < budget {
                let step = min(segment, remaining)
                let done = total - segment + step
                let end = MKMapPoint(x: a.x + (b.x - a.x) * done / total, y: a.y + (b.y - a.y) * done / total)
                if index % 2 == 0 { current.append(end) }
                segment -= step
                remaining -= step
                start = end
                if remaining <= 0 {
                    if index % 2 == 0, current.count >= 2 { pieces.append(current.map(\.coordinate)) }
                    index = (index + 1) % lengths.count
                    remaining = lengths[index]
                    current = [start]
                }
            }
        }
        if index % 2 == 0, current.count >= 2 { pieces.append(current.map(\.coordinate)) }
        return pieces
    }

    /// The ticks of a hatched outline: 1.2 pt lines every 5 pt, 7 pt into the area.
    static func hatchTicks(around ring: [CLLocationCoordinate2D], zoom: Zoom) -> [[CLLocationCoordinate2D]] {
        guard ring.count >= 3, let first = ring.first else { return [] }
        let perPoint = zoom.metersPerPoint * MKMapPointsPerMeterAtLatitude(first.latitude)
        let spacing = 5 * perPoint, length = 7 * perPoint
        guard spacing > 0, spacing.isFinite else { return [] }
        let points = (ring + [first]).map(MKMapPoint.init)
        // Map points run east and SOUTH: a positive shoelace sum is clockwise on the map, so the inside
        // is on the right of the way round.
        let area = zip(points, points.dropFirst()).reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
        let inwardSign: Double = area > 0 ? 1 : -1
        var ticks: [[CLLocationCoordinate2D]] = []
        var carry = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let edge = (dx * dx + dy * dy).squareRoot()
            guard edge > 0 else { continue }
            let (ux, uy) = (dx / edge, dy / edge)
            let (nx, ny) = (-uy * inwardSign, ux * inwardSign)
            var along = carry
            while along < edge, ticks.count < 4_000 {
                let base = MKMapPoint(x: a.x + ux * along, y: a.y + uy * along)
                let tip = MKMapPoint(x: base.x + nx * length, y: base.y + ny * length)
                ticks.append([base.coordinate, tip.coordinate])
                along += spacing
            }
            carry = along - edge
        }
        return ticks
    }

    /// A route's arrowhead: a chevron at the end `item.arrow` says, 12 pt long at `zoom`, its casing
    /// under its core. None for a circuit.
    static func arrowheadOverlays(for item: VFRMapItem, zoom: Zoom) -> [MKOverlay] {
        let procedure = item.procedure
        guard let chevron = chevron(for: item, lengthMeters: arrowheadPoints * zoom.metersPerPoint) else { return [] }
        return [VFRStroke.casing, .core].map { stroke in
            let arrow = VFRRouteOverlay(coordinates: chevron, count: chevron.count)
            arrow.procedureId = procedure.id
            arrow.drawKey = item.drawKey
            arrow.stroke = stroke
            arrow.kind = procedure.kind
            arrow.categories = procedure.categories
            arrow.isApproximate = procedure.isApproximate
            return arrow
        }
    }

    /// Wing, tip, wing: the tip on the line's end, the wings 30° either side of the line, back along its
    /// last (or first) segment.
    static func chevron(for item: VFRMapItem, lengthMeters: Double) -> [CLLocationCoordinate2D]? {
        let line = item.procedure.line
        let tip: VFRCoordinate, from: VFRCoordinate?
        switch item.arrow {
        case .none: return nil
        case .atEnd:
            guard let last = line.last else { return nil }
            (tip, from) = (last, line.dropLast().last { $0 != last })
        case .atStart:
            guard let first = line.first else { return nil }
            (tip, from) = (first, line.dropFirst().first { $0 != first })
        }
        guard let from, lengthMeters > 0, lengthMeters.isFinite else { return nil }
        let tipPoint = MKMapPoint(tip.coordinate)
        let fromPoint = MKMapPoint(from.coordinate)
        let dx = tipPoint.x - fromPoint.x, dy = tipPoint.y - fromPoint.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return nil }
        let back = lengthMeters * MKMapPointsPerMeterAtLatitude(tip.latitude)
        let (ux, uy) = (dx / length, dy / length)
        let angle = Double.pi / 6
        func wing(_ sign: Double) -> CLLocationCoordinate2D {
            let c = cos(angle), s = sin(angle) * sign
            let wx = -(ux * c - uy * s), wy = -(ux * s + uy * c)
            return MKMapPoint(x: tipPoint.x + wx * back, y: tipPoint.y + wy * back).coordinate
        }
        return [wing(1), tip.coordinate, wing(-1)]
    }

    /// Where an overlay goes among the procedures', bottom to top: the sectors (fill, outline, hatch);
    /// the routes' casings, their cores, their arrowheads; the circuits' casings, then their cores. All
    /// casings under all cores of a tier, so a casing never cuts another line where they cross; the
    /// circuits over the routes, which often join them on the crosswind or downwind (their dashes over
    /// the circuit's solid line read as one dash-dot line).
    static func tier(of overlay: MKOverlay) -> Int? {
        switch overlay {
        case is VFRSectorOverlay:
            return 0
        case let dash as VFRDashOverlay:
            switch dash.role {
            case .sectorOutline, .hatch: return 1
            case .route: return dash.stroke == .casing ? 2 : 3
            case .circuit: return dash.stroke == .casing ? 6 : 7
            }
        case let arrow as VFRRouteOverlay:
            return arrow.stroke == .casing ? 4 : 5
        case let circuit as VFRCircuitOverlay:
            return circuit.stroke == .casing ? 6 : 7
        default:
            return nil
        }
    }

    /// Under the route and the flight's lines (the aircraft is an annotation, above every overlay), above
    /// the chart tiles and the airspace drawn so far, and in its tier among the procedures'.
    static func insert(_ overlay: MKOverlay, on mapView: MKMapView) {
        let mine = tier(of: overlay) ?? 0
        let stack = mapView.overlays(in: .aboveLabels)
        let anchor = stack.firstIndex { other in
            isRouteOverlay(other) || (tier(of: other).map { $0 > mine } ?? false)
        }
        if let anchor {
            mapView.insertOverlay(overlay, at: anchor, level: .aboveLabels)
        } else {
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    /// The renderer for a procedure's shape; nil for any other overlay. Every map asks this before its
    /// generic `MKPolyline` branch. MapKit's own renderers, configured, with no dash pattern: they draw
    /// as vectors, the same size at every zoom.
    nonisolated static func renderer(for overlay: MKOverlay, palette: VFRMapPalette) -> MKOverlayRenderer? {
        switch overlay {
        case let circuit as VFRCircuitOverlay:
            let style = VFRLineStyle.style(kind: .circuit, categories: circuit.categories,
                                           approximate: circuit.isApproximate)
            let renderer = MKPolylineRenderer(polyline: circuit)
            configure(renderer, style: style, stroke: circuit.stroke, palette: palette, dashed: false)
            return renderer
        case let arrow as VFRRouteOverlay:
            let style = VFRLineStyle.style(kind: arrow.kind, categories: arrow.categories,
                                           approximate: arrow.isApproximate).arrowhead
            let renderer = MKPolylineRenderer(polyline: arrow)
            configure(renderer, style: style, stroke: arrow.stroke, palette: palette, dashed: false)
            return renderer
        case let dash as VFRDashOverlay:
            let renderer = MKMultiPolylineRenderer(multiPolyline: dash)
            switch dash.role {
            case .sectorOutline:
                renderer.strokeColor = palette.sectorStroke
                renderer.lineWidth = dash.style.coreWidth
                renderer.lineCap = .butt
            case .hatch:
                renderer.strokeColor = palette.noise
                renderer.lineWidth = dash.style.coreWidth
                renderer.lineCap = .butt
            case .route, .circuit:
                configure(renderer, style: dash.style, stroke: dash.stroke, palette: palette, dashed: true)
            }
            return renderer
        case let sector as VFRSectorOverlay:
            let renderer = MKPolygonRenderer(polygon: sector)
            if sector.areaKind == .noise {
                renderer.strokeColor = palette.noise
                renderer.lineWidth = 1.5
                renderer.fillColor = nil
            } else {
                renderer.fillColor = palette.sectorFill
                renderer.strokeColor = nil
            }
            return renderer
        default:
            return nil
        }
    }

    /// One stroke of a line: the casing (round caps, so each dash and dot is outlined) or the core.
    nonisolated static func configure(_ renderer: MKOverlayPathRenderer, style: VFRLineStyle, stroke: VFRStroke,
                                      palette: VFRMapPalette, dashed: Bool) {
        renderer.lineJoin = .round
        switch stroke {
        case .casing:
            renderer.strokeColor = palette.casing.withAlphaComponent(palette.casing.cgColor.alpha * style.alpha)
            renderer.lineWidth = style.casingWidth
            renderer.lineCap = .round
        case .core:
            renderer.strokeColor = palette.procedure.withAlphaComponent(style.alpha)
            renderer.lineWidth = style.coreWidth
            renderer.lineCap = style.isDotted || !dashed ? .round : .butt
        }
    }

    /// A label's view, with its callout; nil for any other annotation.
    /// - Parameters:
    ///   - metrics: the callout's buttons, the Cockpit's sizes in flight.
    ///   - openChart: opens the aerodrome's official chart; nil leaves the button out. (6.2.0)
    static func annotationView(for annotation: MKAnnotation, on mapView: MKMapView,
                               palette: VFRMapPalette, metrics: CalloutMetrics = .ground,
                               openChart: ((URL) -> Void)? = nil) -> MKAnnotationView? {
        guard let label = annotation as? VFRProcedureAnnotation else { return nil }
        let id = "VFRProcedureLabel"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
            ?? MKAnnotationView(annotation: label, reuseIdentifier: id)
        view.annotation = label
        let kind = label.item.procedure.kind
        view.image = VFRProcedureLabelImage.image(text: label.item.labelText, kind: kind, palette: palette)
        view.centerOffset = .zero
        view.canShowCallout = true
        // Labels give way to each other and to the markers that must show: MapKit hides the colliding ones.
        view.displayPriority = .defaultHigh
        view.collisionMode = .rectangle
        view.detailCalloutAccessoryView = VFRProcedureCallout.detailView(for: label.item, at: label.coordinate,
                                                                         palette: palette, metrics: metrics,
                                                                         openChart: openChart)
        view.leftCalloutAccessoryView = nil
        view.rightCalloutAccessoryView = nil
        view.isAccessibilityElement = true
        view.accessibilityLabel = VFRProcedureCallout.summary(for: label.item)
        view.accessibilityTraits = .button
        return view
    }
}

// MARK: - Callout

/// What the callout says: the procedure, where it comes from, that it is indicative, and how to report
/// an error to open flightmaps.
enum VFRProcedureCallout {
    /// "Traffic circuit · 2900 ft · LSZQ", "VFR arrival · Sector · LSZQ".
    static func summary(for item: VFRMapItem) -> String {
        let procedure = item.procedure
        var parts = [VFRMapStrings.kindName(procedure.kind)]
        let areaKinds = Set(procedure.areas.map(\.kind))
        if areaKinds.contains(.corridor) || areaKinds.contains(.area) { parts.append(L10n.VFRMap.sector) }
        if areaKinds.contains(.noise) { parts.append(L10n.VFRMap.noiseArea) }
        if procedure.kind == .circuit { parts.append(item.labelText) }
        parts.append(procedure.aerodrome)
        return parts.joined(separator: " · ")
    }

    /// "open flightmaps · AIRAC 2610 · indicative, check the official chart"; `short`, without the advice,
    /// on one line, where the official chart's button is right under it.
    static func sourceLine(for item: VFRMapItem, short: Bool = false) -> String {
        if short { return item.airac.map(L10n.VFRMap.sourceShortWithCycle) ?? L10n.VFRMap.sourceShort }
        return item.airac.map(L10n.VFRMap.sourceWithCycle) ?? L10n.VFRMap.source
    }

    @MainActor
    static func detailView(for item: VFRMapItem, at coordinate: CLLocationCoordinate2D,
                           palette: VFRMapPalette = .day, metrics: CalloutMetrics = .ground,
                           openChart: ((URL) -> Void)? = nil) -> UIView {
        let summaryLabel = UILabel()
        summaryLabel.text = summary(for: item)
        summaryLabel.font = UIFont.aero(size: CockpitType.size(kneeboard: 17, phone: 15), weight: .semibold)
        summaryLabel.textColor = .label
        summaryLabel.numberOfLines = 0

        // The aerodrome's official chart first (what "check the official chart" asks for), then Report an
        // error. One above the other: side by side, with their whole titles, they are wider than the
        // callout. On the phone in flight, side by side with short titles, and the source on one line:
        // stacked at the Cockpit's size, the callout was about as tall as the phone's chart.
        let chart = openChart == nil ? nil : OfficialChartService.shared.link(for: item.procedure.aerodrome, type: nil)
        let spansCallout = metrics.sideBySide && chart != nil

        var rows: [UIView] = [summaryLabel]
        if item.procedure.isApproximate {
            rows.append(captionLabel(L10n.VFRMap.approximateShape))
        }
        rows.append(captionLabel(sourceLine(for: item, short: spansCallout)))

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 12
        actions.alignment = .center
        if let openChart, let chart {
            actions.axis = spansCallout ? .horizontal : .vertical
            actions.distribution = spansCallout ? .fillEqually : .fill
            actions.spacing = 8
            actions.alignment = .fill
            actions.addArrangedSubview(OfficialChartControl.action(link: chart, metrics: metrics, tint: palette.action,
                                                                   open: openChart))
        }
        actions.addArrangedSubview(reportButton(for: item, at: coordinate, palette: palette, metrics: metrics,
                                                short: spansCallout))
        rows.append(actions)

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        if spansCallout {
            // Two equal halves of the callout's width, the largest targets it has room for.
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // MapKit ends the callout at its detail view's last baseline, and a stack's is the title of its
        // last button, so the bottom of that button was cut off (14 pt of the 64 pt one in flight, the
        // rounded corners at 44 pt). The container's last baseline is its bottom.
        let container = CalloutDetailContainer(content: stack)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// A callout's detail: hung from its content's first baseline, as the stack was, and ending at its
    /// own bottom rather than at a button's title.
    private final class CalloutDetailContainer: UIView {
        private let content: UIView

        init(content: UIView) {
            self.content = content
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
        }

        required init?(coder: NSCoder) { nil }

        override var forFirstBaselineLayout: UIView { content.forFirstBaselineLayout }
        override var forLastBaselineLayout: UIView { self }
    }

    private static func captionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.aero(size: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }

    @MainActor
    private static func reportButton(for item: VFRMapItem, at coordinate: CLLocationCoordinate2D,
                                     palette: VFRMapPalette, metrics: CalloutMetrics, short: Bool) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = short ? L10n.VFRMap.reportShort : L10n.VFRMap.reportError
        configuration.image = UIImage(systemName: "exclamationmark.bubble")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = palette.action
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.aero(size: metrics.fontSize, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            openReport(for: item, at: coordinate)
        })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.target).isActive = true
        button.accessibilityLabel = L10n.VFRMap.reportError
        return button
    }

    /// Open OFM's form (or a mail to OFM), pre-filled from the procedure. Never with the pilot's address.
    @MainActor
    static func openReport(for item: VFRMapItem, at coordinate: CLLocationCoordinate2D) {
        let index = OFMDataService.shared.index
        let report = OFMErrorReport(item: item, position: coordinate)
        guard let url = report.url(form: index?.reportForm, mail: index?.reportMail) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Error report

/// An error report to open flightmaps about one procedure: OFM's form, with its description field
/// filled (`index.json`'s `reportForm`), or else a mail to its address (`reportMail`). The text names
/// the region, the cycle, the aerodrome, the procedure and OFM's id, and where it is on the map, in
/// English, OFM's working language. Nothing about the pilot: the form and the mail app ask for that.
struct OFMErrorReport: Equatable {
    static let defaultMail = "info@openflightmaps.org"

    let country: String
    let region: String?
    let airac: String?
    let aerodrome: String
    let procedureName: String
    let kind: VFRProcedure.Kind
    let ofmId: String
    let latitude: Double
    let longitude: Double

    init(item: VFRMapItem, position: CLLocationCoordinate2D) {
        country = item.country
        region = item.region
        airac = item.airac
        aerodrome = item.procedure.aerodrome
        procedureName = item.procedure.name
        kind = item.procedure.kind
        ofmId = item.procedure.ofmId
        latitude = position.latitude
        longitude = position.longitude
    }

    private var kindText: String {
        switch kind {
        case .circuit: return "traffic circuit"
        case .arrival: return "VFR arrival"
        case .departure: return "VFR departure"
        }
    }

    var subject: String { "open flightmaps data: \(aerodrome) \(procedureName.isEmpty ? kindText : procedureName)" }

    var body: String {
        let position = String(format: "%.5f %@, %.5f %@", abs(latitude), latitude >= 0 ? "N" : "S",
                              abs(longitude), longitude >= 0 ? "E" : "W")
        return """
        Region: \(region.map { "\($0) (\(country))" } ?? country)
        AIRAC: \(airac ?? "unknown")
        Aerodrome: \(aerodrome)
        Procedure: \(procedureName.isEmpty ? kindText : "\(procedureName) (\(kindText))")
        OFM id: \(ofmId)
        Map position: \(position)
        Reported from AeroCheck (aerocheck.app). What is wrong:

        """
    }

    /// The form's URL with the description in its field, when the index names an HTTPS form; else a
    /// `mailto:` with the same text, to the index's address or OFM's.
    func url(form: OFMIndex.ReportForm?, mail: String?) -> URL? {
        if let form, form.url.scheme?.lowercased() == "https", form.url.host != nil, !form.field.isEmpty,
           var components = URLComponents(url: form.url, resolvingAgainstBaseURL: false) {
            var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != Self.encode(form.field) }
            items.append(URLQueryItem(name: Self.encode(form.field), value: Self.encode(body)))
            components.percentEncodedQueryItems = items
            if let url = components.url { return url }
        }
        let address = mail.flatMap(Self.plainAddress) ?? Self.defaultMail
        return URL(string: "mailto:\(address)?subject=\(Self.encode(subject))&body=\(Self.encode(body))")
    }

    /// Percent-encoding of everything but the unreserved characters: `+`, `&`, `=` and spaces included,
    /// which a query would otherwise read as separators.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// An address with nothing a `mailto:` would read as more than an address.
    private static func plainAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._+")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return trimmed
    }
}

// MARK: - Names

enum VFRMapStrings {
    static func kindName(_ kind: VFRProcedure.Kind) -> String {
        switch kind {
        case .circuit: return L10n.VFRMap.trafficCircuit
        case .arrival: return L10n.VFRMap.arrival
        case .departure: return L10n.VFRMap.departure
        }
    }

    /// The Map sheet's credit: "Circuits & VFR routes © open flightmaps · AIRAC 2610 · indicative", with
    /// every cycle on disk ("2610/2611" in the week a country is a cycle behind).
    static func credit(cycles: [String]) -> String {
        let unique = Array(Set(cycles)).sorted()
        return unique.isEmpty ? L10n.VFRMap.credit : L10n.VFRMap.creditWithCycle(unique.joined(separator: "/"))
    }
}
