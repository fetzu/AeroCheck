import MapKit
import MapLibre
import UIKit

// MARK: - The map's markers on MapLibre (6.8.0)

/// `AeroMapView`'s markers drawn by MapLibre (the plan's PR 7): the aircraft, aerodromes, navaids, reporting points,
/// obstacles, the route's waypoints, the route builder's pins, and the procedures' labels (a circuit's altitude, a sector's letter, a
/// route's name, the approach view's runway numbers), each with what a tap on it does: the aerodrome's card, a callout
/// with its "+" for the route being planned, a procedure's callout, a waypoint's time over.
///
/// As with the lines (`PilotMapShapes`), nothing here decides a look. A marker is the annotation the MapKit view would
/// add (`AirportAnnotation`, `VFRProcedureAnnotation`…), wrapped for MapLibre, drawn with the image the MapKit view
/// draws (`AeroMarkerImages`, `VFRMapLayer.labelImage`), and its callout holds the same content (`AerodromeCardView`,
/// `VFRProcedureCallout.detailView`, the reporting point's detail). The markers are views, as MapKit's are, so a pill
/// turns along its downwind and a callout's buttons answer as before.
@MainActor
final class PilotMapMarkers {
    /// The route being planned: its "+" and its pins' selection, as the MapKit view's (`PlannedRouteLayer`).
    private(set) lazy var plannedRoute = PlannedRouteLayer()
    private var markers: [String: PilotMarker] = [:]
    private var signature: Int?
    private var palette: VFRMapPalette = .day
    /// The map's heading the pills were turned for, and the zoom they were stacked at.
    private var pillsFor: (heading: Double, zoom: Double)?
    /// The aircraft: one marker, moved in place, above every other as on MapKit.
    private let aircraft = PilotAircraftMarker()
    private var aircraftShown = false

    nonisolated init() {}

    // MARK: Sync

    /// The markers `map` shows, added and removed by key: nothing while they are the ones on the map.
    func sync(_ map: AeroMapView, on mapView: MLNMapView) {
        plannedRoute.route = map.shownPlannedRoute
        syncAircraft(map, on: mapView)
        let content = map.shownProcedures
        let plan = map.shownPlan
        let planned = map.shownPlannedRoute
        let revision = ReportingPointAnnotation.labelRevision
        let wanted = Self.wanted(map: map, content: content, plan: plan, planned: planned, revision: revision)
        let signature = PilotMapShapes.hash(wanted.map(\.key).sorted(), content.palette.rawValue)
        guard signature != self.signature else { return }
        self.signature = signature
        let paletteChanged = palette != content.palette
        palette = content.palette

        let keys = Set(wanted.map(\.key))
        let stale = markers.filter { !keys.contains($0.key) || (paletteChanged && $0.value.isProcedure) }
        if !stale.isEmpty {
            mapView.removeAnnotations(Array(stale.values))
            for key in stale.keys { markers[key] = nil }
        }
        let added = wanted.filter { markers[$0.key] == nil }.map { PilotMarker(base: $0.make(), key: $0.key) }
        for marker in added { markers[marker.key] = marker }
        if !added.isEmpty { mapView.addAnnotations(added) }
        pillsFor = nil
        layout(on: mapView, atRest: true)
    }

    /// The aircraft on its cached course (it survives GPS gaps), moved rather than replaced so it doesn't blink.
    private func syncAircraft(_ map: AeroMapView, on mapView: MLNMapView) {
        guard let location = map.shownAircraft else {
            if aircraftShown { mapView.removeAnnotation(aircraft); aircraftShown = false }
            return
        }
        aircraft.heading = map.cachedHeading ?? (location.course >= 0 ? location.course : 0)
        let moved = abs(aircraft.coordinate.latitude - location.coordinate.latitude) > 0.00001
            || abs(aircraft.coordinate.longitude - location.coordinate.longitude) > 0.00001
        if moved { aircraft.coordinate = location.coordinate }
        if !aircraftShown { mapView.addAnnotation(aircraft); aircraftShown = true }
        turnAircraft(on: mapView)
    }

    /// The ownship turned to its heading on screen: its view stays upright with the map, so a track-up map's turn
    /// comes off. The symbol points east.
    private func turnAircraft(on mapView: MLNMapView) {
        guard aircraftShown, let view = mapView.view(for: aircraft) else { return }
        view.transform = CGAffineTransform(rotationAngle: CGFloat((aircraft.heading - mapView.direction - 90) * .pi / 180))
    }

    /// One marker the map should show: its key, and how to make it (only when it is new).
    struct Wanted {
        let key: String
        let make: () -> MKAnnotation
    }

    static func wanted(map: AeroMapView, content: VFRMapContent, plan: FlightPlan?, planned: PlannedRoute,
                       revision: Int) -> [Wanted] {
        var out: [Wanted] = []
        for airport in map.shownAirports {
            let lines = map.airportFrequencyLines[airport.ident]
            out.append(Wanted(key: "apt|\(airport.id)") { AirportAnnotation(airport: airport, frequencyLines: lines) })
        }
        for navaid in map.shownNavaids {
            out.append(Wanted(key: "nav|\(navaid.id)") { NavaidAnnotation(navaid: navaid) })
        }
        for obstacle in map.shownObstacles {
            out.append(Wanted(key: "obs|\(obstacle.id)") { ObstacleAnnotation(obstacle: obstacle) })
        }
        // A label's revision in the key: a point renamed is a new marker. (6.0.1)
        for point in map.shownReportingPoints {
            out.append(Wanted(key: "rp|\(point.id)|\(revision)") { ReportingPointAnnotation(point: point) })
        }
        if let plan, plan.waypoints.count >= 2 {
            let current = plan.currentWaypointIndex
            for (index, waypoint) in plan.waypoints.enumerated() {
                let name = waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name
                let state = index == current ? "c" : index < current ? "d" : "f"
                out.append(Wanted(key: "wpt|\(index)|\(state)|\(waypoint.latitude),\(waypoint.longitude)|\(name)") {
                    FlightPlanWaypointAnnotation(coordinate: waypoint.coordinate, name: name, index: index, currentIndex: current)
                })
            }
        }
        for (index, waypoint) in planned.waypoints.enumerated() {
            let conflict = planned.conflictLegs.contains(index)
            out.append(Wanted(key: "pin|\(index)|\(waypoint.latitude),\(waypoint.longitude)|\(conflict)|\(waypoint.name)") {
                let pin = RouteWaypointAnnotation(coordinate: waypoint.coordinate, index: index, name: waypoint.name)
                pin.hasConflict = conflict
                return pin
            })
        }
        if content.showsLabels {
            for item in content.items {
                out.append(Wanted(key: "vfr|\(item.labelKey)") { VFRProcedureAnnotation(item: item) })
            }
        }
        for annotation in content.approach.flatMap(VFRApproachAnnotation.annotations(for:)) {
            out.append(Wanted(key: "app|\(annotation.labelKey)") { annotation })
        }
        return out
    }

    // MARK: Views

    /// The aircraft's view: the ownship, with its shadow, above the other markers.
    func view(for aircraft: PilotAircraftMarker, on mapView: MLNMapView) -> MLNAnnotationView {
        let view = PilotMarkerView(reuseIdentifier: nil)
        view.annotation = aircraft
        view.show(AeroMapView.ownshipImage, shadow: true)
        view.layer.shadowRadius = 3
        view.layer.zPosition = 1000
        view.isEnabled = false
        view.accessibilityLabel = nil
        view.isAccessibilityElement = false
        view.transform = CGAffineTransform(rotationAngle: CGFloat((aircraft.heading - mapView.direction - 90) * .pi / 180))
        return view
    }

    func view(for marker: PilotMarker, on mapView: MLNMapView, inFlight: Bool) -> MLNAnnotationView {
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: PilotMarkerView.reuseIdentifier) as? PilotMarkerView)
            ?? PilotMarkerView(reuseIdentifier: PilotMarkerView.reuseIdentifier)
        view.annotation = marker
        view.accessibilityLabel = Self.accessibilityLabel(for: marker.base)
        switch marker.base {
        case let airport as AirportAnnotation:
            view.show(AeroMarkerImages.airport(airport.airport))
        case is NavaidAnnotation:
            view.show(AeroMarkerImages.navaid)
        case is ObstacleAnnotation:
            view.show(AeroMarkerImages.obstacle)
        case let point as ReportingPointAnnotation:
            view.show(AeroMarkerImages.reportingPoint(compulsory: point.point.compulsory))
        case let waypoint as FlightPlanWaypointAnnotation:
            view.show(AeroMarkerImages.waypoint(waypoint), shadow: true)
            view.onLongPress = { [weak self] in self?.onWaypointLongPress?(waypoint.waypointIndex) }
        case let pin as RouteWaypointAnnotation:
            // The balloon's tip on the waypoint, as MapKit's marker.
            let image = Self.pinImage(number: pin.index + 1, conflict: pin.hasConflict)
            view.show(image, offset: CGVector(dx: 0, dy: -image.size.height / 2))
        case let label as VFRProcedureAnnotation:
            if case .altitude = label.item.labelStyle {
                view.show(VFRProcedureLabelImage.pillImage(text: label.item.labelText, palette: palette))
            } else {
                view.show(VFRMapLayer.labelImage(for: label, palette: palette))
            }
            view.accessibilityLabel = VFRProcedureCallout.summary(for: label.item)
        case let approach as VFRApproachAnnotation:
            let (image, spoken) = VFRMapLayer.approachImage(for: approach, palette: palette)
            view.show(image)
            view.accessibilityLabel = spoken
        default:
            view.show(nil)
        }
        if marker.base is VFRProcedureAnnotation { pillsFor = nil }
        return view
    }

    /// A tap or a long press on a waypoint in flight: its time over (`AeroMapView.atoTap`).
    var onWaypointLongPress: ((Int) -> Void)?

    static func accessibilityLabel(for annotation: MKAnnotation) -> String? {
        [annotation.title ?? nil, annotation.subtitle ?? nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// The route builder's numbered pin: a balloon in navigation magenta, amber where the leg from it has a conflict,
    /// as MapKit's marker draws it. (planning proposal D2)
    static func pinImage(number: Int, conflict: Bool) -> UIImage {
        let tint = conflict ? UIColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1) : UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1)
        let size = CGSize(width: 30, height: 40)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let circle = CGRect(x: 1, y: 1, width: 28, height: 28)
            let path = UIBezierPath(ovalIn: circle)
            path.move(to: CGPoint(x: 8, y: 25))
            path.addLine(to: CGPoint(x: 15, y: 39))
            path.addLine(to: CGPoint(x: 22, y: 25))
            path.close()
            tint.setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.aero(size: 14, weight: .bold),
                                                             .foregroundColor: UIColor.white]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: circle.midX - textSize.width / 2, y: circle.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    // MARK: Layout

    /// As the map moves: the circuits' pills turned along their downwind and stacked (`VFRMapLayer.pillSlots`), the
    /// callout over its marker; `atRest`, also the routes' names that would cover a marker or another name hidden
    /// (MapKit's collision), which waits for the map to stop.
    func layout(on mapView: MLNMapView, atRest: Bool) {
        let labels = markers.values.filter { $0.base is VFRProcedureAnnotation }
        let heading = mapView.direction
        if !labels.isEmpty, pillsFor.map({ abs($0.heading - heading) > 0.5 || abs($0.zoom - mapView.zoomLevel) > 0.05 }) ?? true {
            pillsFor = (heading, mapView.zoomLevel)
            let annotations = labels.compactMap { $0.base as? VFRProcedureAnnotation }
            let slots = VFRMapLayer.pillSlots(for: annotations, heading: heading) { mapView.convert($0, toPointTo: mapView) }
            for marker in labels {
                guard let label = marker.base as? VFRProcedureAnnotation,
                      case .altitude(let leg, let outsideLeft) = label.item.labelStyle, leg.count == 2,
                      let view = mapView.view(for: marker) as? PilotMarkerView else { continue }
                let turn = VFRMapLayer.labelTurn(leg: leg, outsideLeft: outsideLeft, heading: heading)
                let slot = slots[label.labelKey] ?? .level(0)
                let level: Int
                if case .level(let n) = slot { level = n } else { level = 0 }
                let offset = VFRPill.offset(size: VFRProcedureLabelImage.pillBox(text: label.item.labelText), level: level,
                                            gap: VFRProcedureLabelImage.sideGap, angle: turn.angle, above: turn.above)
                view.showPill(VFRProcedureLabelImage.pillImage(text: label.item.labelText, palette: palette), angle: turn.angle,
                              offset: offset, duplicate: slot == .duplicate)
            }
        }
        if atRest { hideCollidingNames(on: mapView) }
        turnAircraft(on: mapView)
        (selectedCallout(on: mapView))?.place(on: mapView, moving: false)
    }

    /// Routes' names give way to every other marker and to each other, as MapKit's lower display priority did.
    private func hideCollidingNames(on mapView: MLNMapView) {
        var taken: [CGRect] = []
        var names: [(PilotMarkerView, CGRect)] = []
        for marker in markers.values {
            guard let view = mapView.view(for: marker) as? PilotMarkerView, view.superview != nil else { continue }
            let frame = view.convert(view.bounds, to: mapView)
            if let label = marker.base as? VFRProcedureAnnotation, case .name = label.item.labelStyle {
                names.append((view, frame))
            } else if !view.isHidden {
                taken.append(view.drawnFrame(in: mapView))
            }
        }
        for (view, frame) in names.sorted(by: { ($0.0.annotation as? PilotMarker)?.key ?? "" < ($1.0.annotation as? PilotMarker)?.key ?? "" }) {
            let drawn = view.drawnFrame(in: mapView)
            let hidden = taken.contains { $0.intersects(drawn) }
            view.isHidden = hidden
            if !hidden { taken.append(frame) }
        }
    }

    // MARK: Callouts

    /// What a marker's tap opens: its card or callout, or nothing (a runway number; a waypoint, whose tap is its time
    /// over).
    static func hasCallout(_ annotation: MKAnnotation) -> Bool {
        !(annotation is VFRApproachAnnotation || annotation is FlightPlanWaypointAnnotation)
    }

    private weak var callout: PilotMarkerCallout?

    func selectedCallout(on mapView: MLNMapView) -> PilotMarkerCallout? {
        guard let callout, callout.superview != nil else { return nil }
        return callout
    }

    /// The marker's card (an aerodrome) or callout (the rest), its actions wired to `map`.
    func callout(for marker: PilotMarker, map: AeroMapView, on mapView: MLNMapView,
                 close: @escaping () -> Void) -> PilotMarkerCallout {
        let metrics = CalloutMetrics.metrics(inFlight: map.isInFlight)
        let content: UIView
        switch marker.base {
        case let airport as AirportAnnotation:
            let ref = AerodromeRef(airport.airport)
            let card = AerodromeCardContent.make(
                airport: airport.airport, frequencyLines: airport.frequencyLines,
                note: map.features.contains(.noteCallout) ? AerodromeNoteStore.shared.note(for: ref) : nil,
                inFlight: map.isInFlight,
                chart: map.chartOpener == nil ? nil : OfficialChartService.shared.link(for: airport.airport),
                canOpenNote: map.noteOpener != nil,
                canDivert: map.activeFlightPlan != nil && map.divertHandler != nil,
                canAddToRoute: plannedRoute.canAdd(airport))
            let area = PilotMarkerCallout.area(of: mapView)
            let width = min(AerodromeCardView.maxWidth(metrics: metrics), max(area.width, 240))
            content = AerodromeCardView(content: card, metrics: metrics, tint: palette.action, width: width) {
                [weak self] action in
                close()
                switch action {
                case .chart(let link): map.chartOpener?(link.url)
                case .note: map.noteOpener?(ref)
                case .divert: map.divertHandler?(airport.airport.ident)
                case .addToRoute: self?.plannedRoute.add(airport)
                }
            }
        case let label as VFRProcedureAnnotation:
            content = PilotMarkerBubble(title: label.title, subtitle: nil,
                                        detail: VFRProcedureCallout.detailView(for: label.item, at: label.coordinate,
                                                                              palette: palette, metrics: metrics,
                                                                              openChart: map.chartOpener),
                                        add: nil)
        default:
            let base = marker.base
            let detail = (base as? ReportingPointAnnotation)?.calloutDetailView()
            let add: (() -> Void)? = plannedRoute.canAdd(base) && !(base is AirportAnnotation)
                ? { [weak self] in close(); self?.plannedRoute.add(base) } : nil
            content = PilotMarkerBubble(title: base.title ?? nil, subtitle: detail == nil ? base.subtitle ?? nil : nil,
                                        detail: detail, add: add)
        }
        let callout = PilotMarkerCallout(marker: marker, content: content)
        self.callout = callout
        return callout
    }

    /// A search's aerodrome: its card, once the camera has arrived and its marker is on the map (MapKit's
    /// `AirfieldSearch.openPendingCallout`).
    func openPendingCallout(on mapView: MLNMapView, mapState: SharedMapState, now: Date = Date()) {
        guard let pending = mapState.pendingCallout else { return }
        guard now < pending.until else { mapState.pendingCallout = nil; return }
        let bounds = mapView.visibleCoordinateBounds
        let span = MKCoordinateSpan(latitudeDelta: abs(bounds.ne.latitude - bounds.sw.latitude),
                                    longitudeDelta: abs(bounds.ne.longitude - bounds.sw.longitude))
        guard AirfieldSearch.hasArrived(at: pending, center: mapView.centerCoordinate, span: span),
              let marker = markers.values.first(where: { ($0.base as? AirportAnnotation)?.airport.ident == pending.ident })
        else { return }
        mapView.selectAnnotation(marker, animated: true, completionHandler: nil)
        mapState.pendingCallout = nil
    }
}

// MARK: - A marker

/// A MapKit annotation on MapLibre: the same object the MapKit view adds, so every helper that reads one (the route's
/// "+", the card's content) reads this.
final class PilotMarker: NSObject, MLNAnnotation {
    let base: MKAnnotation
    let key: String

    init(base: MKAnnotation, key: String) {
        self.base = base
        self.key = key
    }

    var coordinate: CLLocationCoordinate2D { base.coordinate }
    var title: String? { base.title ?? nil }
    var subtitle: String? { base.subtitle ?? nil }
    var isProcedure: Bool { base is VFRProcedureAnnotation || base is VFRApproachAnnotation }
}

/// The aircraft's marker: its position moves in place (MapLibre follows `coordinate`), its heading turns its view.
final class PilotAircraftMarker: NSObject, MLNAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var heading: Double = 0
}

/// A marker's view: its image on the coordinate (or off it by `offset`), or a circuit's altitude pill turned along its
/// downwind beside the line, only the pill taking a tap (`VFRAltitudeLabelView`'s geometry).
final class PilotMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "PilotMarker"
    private let imageView = UIImageView()
    private var angle: CGFloat = 0
    private var pillSize: CGSize?
    private var isDuplicate = false
    var onLongPress: (() -> Void)? {
        didSet { longPress.isEnabled = onLongPress != nil }
    }
    /// A tap selects the marker through its map: MapLibre's own hit-testing of view markers missed them (7.0.0-pre2),
    /// and a marker's own recognizer, deeper than the map's, wins over the map's tap.
    private lazy var tap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        return tap
    }()
    private lazy var longPress: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 1.0
        addGestureRecognizer(press)
        return press
    }()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        _ = tap
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onLongPress = nil
        isHidden = false
        layer.shadowOpacity = 0
    }

    /// `image` centred on the coordinate, moved by `offset`.
    func show(_ image: UIImage?, offset: CGVector = .zero, shadow: Bool = false) {
        imageView.transform = .identity
        imageView.image = image
        let size = image?.size ?? .zero
        // At least a finger's width to tap, the image in the middle.
        bounds = CGRect(x: 0, y: 0, width: max(size.width, 30), height: max(size.height, 30))
        imageView.bounds = CGRect(origin: .zero, size: size)
        imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        centerOffset = offset
        angle = 0
        pillSize = nil
        isDuplicate = false
        imageView.isHidden = false
        if shadow {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 2)
            layer.shadowOpacity = 0.5
            layer.shadowRadius = 2
        }
    }

    /// A circuit's altitude pill, as `VFRAltitudeLabelView.show` places it.
    func showPill(_ pill: UIImage, angle: CGFloat, offset: CGPoint, duplicate: Bool) {
        imageView.transform = .identity
        imageView.image = pill
        imageView.bounds = CGRect(origin: .zero, size: pill.size)
        imageView.transform = CGAffineTransform(rotationAngle: angle)
        let tap = VFRAltitudeLabelView.tapSize(pill.size)
        let (c, s) = (abs(cos(angle)), abs(sin(angle)))
        bounds = CGRect(x: 0, y: 0, width: ceil(tap.width * c + tap.height * s), height: ceil(tap.width * s + tap.height * c))
        imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        centerOffset = CGVector(dx: offset.x, dy: offset.y)
        self.angle = angle
        pillSize = pill.size
        isDuplicate = duplicate
        imageView.isHidden = duplicate
    }

    /// What is drawn, in `view`: the image (a pill: its turned box), not the larger tap area.
    func drawnFrame(in view: UIView) -> CGRect {
        imageView.convert(imageView.bounds, to: view)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isDuplicate else { return false }
        guard let pillSize else { return super.point(inside: point, with: event) }
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let (c, s) = (cos(angle), sin(angle))
        let tap = VFRAltitudeLabelView.tapSize(pillSize)
        return abs(dx * c + dy * s) <= tap.width / 2 && abs(-dx * s + dy * c) <= tap.height / 2
    }

    @objc private func tapped() {
        guard let annotation, let mapView = sequence(first: superview, next: { $0?.superview }).lazy
                .compactMap({ $0 as? MLNMapView }).first else { return }
        if mapView.selectedAnnotations.contains(where: { $0 === annotation }) { return }
        mapView.selectAnnotation(annotation, animated: true, completionHandler: nil)
    }

    override func accessibilityActivate() -> Bool {
        tapped()
        return true
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onLongPress?()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - Callouts

/// A marker's card or callout on MapLibre (`MLNCalloutView`): MapLibre adds it when the marker is selected and takes
/// it away when it is not, and a touch on it is the callout's, not the map's. It sits over its marker with its tail on
/// it, sideways inside the map, as `AerodromeMarkerView` places the card on MapKit; `PilotMapMarkers.layout` moves it
/// with the map.
final class PilotMarkerCallout: UIView, MLNCalloutView {
    var representedObject: MLNAnnotation
    var leftAccessoryView = UIView()
    var rightAccessoryView = UIView()
    weak var delegate: MLNCalloutViewDelegate?
    let content: UIView

    var dismissesAutomatically: Bool { false }

    init(marker: PilotMarker, content: UIView) {
        representedObject = marker
        self.content = content
        let size = content.bounds.size == .zero
            ? content.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            : content.bounds.size
        super.init(frame: CGRect(origin: .zero, size: size))
        content.frame = bounds
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Where a callout may sit: the map inside its safe area, a margin from every side.
    static func area(of mapView: UIView) -> CGRect {
        mapView.bounds.inset(by: mapView.safeAreaInsets).insetBy(dx: AerodromeMarkerView.edge, dy: AerodromeMarkerView.edge)
    }

    func presentCallout(from rect: CGRect, in view: UIView, constrainedTo constrainedRect: CGRect, animated: Bool) {
        view.addSubview(self)
        // MapLibre hands over a view of its own inside the map: the map is up the tree.
        if let mapView = sequence(first: view as UIView?, next: { $0?.superview }).lazy.compactMap({ $0 as? MLNMapView }).first {
            place(on: mapView, moving: false)
            // Selected right after a camera move (a search), the marker is placed a turn later: the callout follows, and
            // only then may the map move for it, as `AerodromeMarkerView.show` does on MapKit.
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView, self.superview != nil else { return }
                self.place(on: mapView, moving: true)
            }
        } else {
            frame = AerodromeMarkerView.frame(for: bounds.size, over: CGPoint(x: rect.midX, y: rect.minY), in: Self.area(of: view))
        }
        UIAccessibility.post(notification: .layoutChanged, argument: content)
    }

    func dismissCallout(animated: Bool) {
        removeFromSuperview()
    }

    /// Over the marker's drawn top, its tail on it. With `moving`, a callout that would leave the map at the top moves
    /// the map down until it fits, as MapKit's bubble did.
    func place(on mapView: MLNMapView, moving: Bool) {
        guard let superview, let marker = representedObject as? PilotMarker else { return }
        let top: CGPoint
        if let view = mapView.view(for: marker) as? PilotMarkerView {
            let drawn = view.drawnFrame(in: mapView)
            top = CGPoint(x: drawn.midX, y: drawn.minY)
        } else {
            top = mapView.convert(marker.coordinate, toPointTo: mapView)
        }
        let area = Self.area(of: mapView)
        let frame = AerodromeMarkerView.frame(for: bounds.size, over: top, in: area)
        (content as? AerodromeCardView)?.tailX = top.x - frame.minX
        (content as? PilotMarkerBubble)?.tailX = top.x - frame.minX
        self.frame = superview.convert(frame, from: mapView)
        let shortfall = AerodromeMarkerView.shortfall(of: frame, anchor: top, in: area)
        guard moving, shortfall > 0 else { return }
        let center = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY - shortfall)
        mapView.setCenter(mapView.convert(center, toCoordinateFrom: mapView), animated: true)
    }
}

/// The callout of a marker that isn't an aerodrome: its name, a line under it or its detail (a reporting point's
/// note, a procedure's summary and buttons), and the route's "+" while a route is being planned. MapKit's callout,
/// drawn by the app: a rounded box with a tail, in the system's colours.
final class PilotMarkerBubble: UIView {
    private let shape = CAShapeLayer()
    private let stack = UIStackView()
    private let onAdd: (() -> Void)?
    static let tailHeight: CGFloat = 10
    var tailX: CGFloat = 0 { didSet { setNeedsLayout() } }

    init(title: String?, subtitle: String?, detail: UIView?, add: (() -> Void)?) {
        onAdd = add
        super.init(frame: .zero)
        layer.addSublayer(shape)
        shape.fillColor = UIColor.secondarySystemBackground.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 3
        text.alignment = .leading
        if let title, !title.isEmpty {
            let label = UILabel()
            label.text = title
            label.font = UIFont.aero(size: 17, weight: .semibold)
            label.numberOfLines = 2
            text.addArrangedSubview(label)
        }
        if let subtitle, !subtitle.isEmpty {
            let label = UILabel()
            label.text = subtitle
            label.font = UIFont.aero(size: 13)
            label.textColor = .secondaryLabel
            label.numberOfLines = 3
            text.addArrangedSubview(label)
        }
        if let detail { text.addArrangedSubview(detail) }

        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.addArrangedSubview(text)
        if add != nil {
            let button = AddToRouteButton(type: .contactAdd)
            button.accessibilityLabel = L10n.Nav.addToRoute
            button.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12 - Self.tailHeight),
            widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        let size = systemLayoutSizeFitting(CGSize(width: 340, height: UIView.layoutFittingCompressedSize.height),
                                           withHorizontalFittingPriority: .fittingSizeLevel,
                                           verticalFittingPriority: .fittingSizeLevel)
        frame = CGRect(origin: .zero, size: CGSize(width: max(size.width, 120), height: size.height))
        tailX = bounds.midX
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        let path = UIBezierPath(roundedRect: box, cornerRadius: 12)
        let x = min(max(tailX, 18), bounds.width - 18)
        path.move(to: CGPoint(x: x - 9, y: box.maxY))
        path.addLine(to: CGPoint(x: x, y: bounds.height))
        path.addLine(to: CGPoint(x: x + 9, y: box.maxY))
        path.close()
        shape.path = path.cgPath
        shape.fillColor = UIColor.secondarySystemBackground.resolvedColor(with: traitCollection).cgColor
        layer.shadowPath = path.cgPath
    }
}
