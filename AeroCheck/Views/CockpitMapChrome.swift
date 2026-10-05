import SwiftUI
import MapKit
import CoreLocation

// MARK: - The MAP page's chrome (6.2.0)
//
// What sits over the Cockpit's chart, and nothing else: the chart is the page (the author's "dark
// cockpit", 3 Oct 2026).
//
//   - At the right edge, from its foot: N↑ or TRK, the layers (with the stale-airspace triangle),
//     centre (filled once the map is panned), and zoom + / − on the iPad only. A column where the chart
//     is tall enough, else a row along the foot of the chart, at the right (the iPad on its side).
//   - At the top left, the status slot: one state at a time, the one `CockpitStatusRule` picks (UNDO,
//     NO GPS, OFF ROUTE, CHART OFFLINE, TELL FIS, SIGMET, BRIEFING, GPS DEGRADED), each a tap away from
//     what it is about.
//   - After a pan, an arrow at the chart's edge pointing to the aircraft (`OwnshipEdgeArrow`).
//   - The scale, only from a change of zoom to 2 s after the last one (`ScaleVisibility`).
//
// Every frame comes from the chart's size and the device (`MapChromeGeometry`), never from what is
// shown: centre filled or not, a status or none, N↑ or TRK, the stack doesn't move, and the slot has one
// size whatever state it holds. The view reads no manager: the map hands it plain values and closures,
// so it previews and tests on its own.
//
// Until 6.2 the map carried a labelled row of controls, the next-waypoint card, CACHED / OFFLINE, a
// permanent scale, chips, the off-screen route pill and the undo toast, all over the chart.

/// What the chrome shows: the map's state, as plain values.
struct MapChromeModel {
    var orientation: MapOrientationMode = .northUp
    /// Off the aircraft once panned: centre fills, the edge arrow shows.
    var isFollowingAircraft = true
    /// The downloaded airspace aging or stale: the triangle on the layers button.
    var airspaceNeedsAttention = false
    /// `CockpitStatusRule.current`: the state the slot shows, or nil for a dark slot.
    var status: CockpitStatus? = nil
    /// The offer behind `.undo` (`NavUndoOffer.shown`).
    var undoOffer: NavUndoOffer? = nil
    /// What the chart shows, and the camera's heading (0 north up, the track in track up).
    var region: MKCoordinateRegion
    var heading: Double = 0
    var aircraft: CLLocationCoordinate2D? = nil
    /// The zoom, as `ScaleVisibility` notes it: the camera's distance, which the centre and the heading
    /// leave alone.
    var zoom: Double
    var nauticalMiles = true
}

/// What the chrome's taps do. The map owns them.
struct MapChromeActions {
    var toggleOrientation: () -> Void = {}
    var showLayers: () -> Void = {}
    var centre: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    /// UNDO tapped (after the offer's own undo), or its six seconds over: clear the offer.
    var dismissUndo: (NavUndoOffer) -> Void = { _ in }
    /// A tap on a state: the GPS drawer, the aircraft and its leg framed, the cache info, Divert, the
    /// SIGMETs, the briefing.
    var openStatus: (CockpitStatus) -> Void = { _ in }
}

// MARK: - Geometry

/// Every frame of the chrome over a chart of `size`, from the size and the device alone. Pure: the
/// tests check it, as `RouteTrackBar.placement` is checked for the DEST line. (Plan §5.3)
struct MapChromeGeometry: Equatable {
    enum Control: CaseIterable, Hashable {
        case orientation, layers, centre, zoomIn, zoomOut
    }

    struct Metrics: Equatable {
        /// A control's side: the 15 mm EFB control on the iPad (78 pt, `CockpitTarget.transient`). On the
        /// phone, the act band's narrow slots' 72: three at 92 don't fit a 6.1" phone's chart, about 256
        /// pt tall.
        let button: CGFloat
        let gap: CGFloat
        /// From the chart's edges, as the act band's padding: so the stack lines up with More.
        let margin: CGFloat
        let cornerRadius: CGFloat
        /// The status slot: UNDO's 15 mm button sets its height (78 on the iPad, 92 on the phone).
        let slotHeight: CGFloat
        /// Its width, short of the stack: the iPad's room for "CHECK BEFORE ENGINE START done from
        /// memory" on two lines; on the phone, all there is.
        let slotWidth: CGFloat
        let slotGap: CGFloat
        let slotPadding: CGFloat
        let slotCornerRadius: CGFloat
        /// In-flight text: 20 pt on the iPad, 17 on the phone (`CockpitType.label`).
        let textSize: CGFloat
        /// N↑ and TRK.
        let orientationTextSize: CGFloat
        let controlIconSize: CGFloat
        let statusIconSize: CGFloat
        let statusIconColumn: CGFloat
        let statusIconGap: CGFloat
        /// UNDO: as wide as "ANNULER" needs, as tall as the slot.
        let undoButtonWidth: CGFloat
        /// The undo message's lines: the longest messages in French need them all.
        let undoMessageLines: Int
        let arrowSize: CGFloat
        /// `SwissScaleBar`'s card: at most 150 pt of bar, 50 pt tall.
        let scaleSize: CGSize

        init(_ scale: CockpitScale) {
            let kneeboard = scale == .kneeboard
            button = kneeboard ? 78 : 72
            gap = kneeboard ? 10 : 6
            margin = kneeboard ? 16 : 12
            cornerRadius = kneeboard ? 16 : 14
            slotHeight = kneeboard ? 78 : 92
            slotWidth = kneeboard ? 480 : .infinity
            slotGap = kneeboard ? 12 : 8
            slotPadding = kneeboard ? 16 : 12
            slotCornerRadius = kneeboard ? 14 : 12
            textSize = CockpitType.label(for: scale)
            orientationTextSize = CockpitType.size(kneeboard: 24, phone: 21, scale: scale)
            controlIconSize = CockpitType.size(kneeboard: 26, phone: 22, scale: scale)
            statusIconSize = CockpitType.size(kneeboard: 24, phone: 20, scale: scale)
            statusIconColumn = kneeboard ? 28 : 24
            statusIconGap = kneeboard ? 12 : 8
            undoButtonWidth = kneeboard ? 116 : 96
            undoMessageLines = kneeboard ? 3 : 4
            arrowSize = kneeboard ? 52 : 44
            scaleSize = CGSize(width: 180, height: 50)
        }
    }

    let size: CGSize
    let metrics: Metrics
    /// The controls, in the stack's order: top to bottom in a column, left to right in a row.
    let controls: [Control]
    let frames: [Control: CGRect]
    /// A column up the right edge where the chart is tall enough (the iPad in portrait, the phone);
    /// else a row along its foot, at the right (the iPad on its side, a chart about 270 pt tall).
    let isColumn: Bool
    /// What the stack covers.
    let stack: CGRect
    let statusSlot: CGRect
    let scale: CGRect
    /// Where the edge arrow may sit: under the slot, clear of the stack.
    let arrowBounds: CGRect

    /// Zoom on the iPad only (the author's Q6): the phone pinches.
    static func controls(for scale: CockpitScale) -> [Control] {
        scale == .kneeboard ? Control.allCases : [.orientation, .layers, .centre]
    }

    /// `showsStack`: false while the phone shows a leg from ROUTE, whose bar takes the chart's foot (Back to
    /// aircraft is centre then). `footRoom`: what that bar takes of the foot, kept clear of the scale and
    /// the edge arrow.
    init(size: CGSize, scale: CockpitScale, showsStack: Bool = true, footRoom: CGFloat = 0) {
        let m = Metrics(scale)
        let all = showsStack ? Self.controls(for: scale) : []
        let length = { (count: Int) in CGFloat(count) * m.button + CGFloat(max(count - 1, 0)) * m.gap }
        let isColumn = length(all.count) <= size.height - 2 * m.margin
        // In a row, − before +, as the map's row has them; centre beside them.
        let controls = isColumn ? all : all.filter { $0 != .zoomIn } + (all.contains(.zoomIn) ? [.zoomIn] : [])
        var frames: [Control: CGRect] = [:]
        if isColumn {
            let top = size.height - m.margin - length(controls.count)
            for (index, control) in controls.enumerated() {
                frames[control] = CGRect(x: size.width - m.margin - m.button, y: top + CGFloat(index) * (m.button + m.gap),
                                         width: m.button, height: m.button)
            }
        } else {
            // Rows from the foot up if even a row doesn't fit across (no iPad), each at the right edge.
            let perRow = max(1, Int(((size.width - 2 * m.margin + m.gap) / (m.button + m.gap)).rounded(.down)))
            let lines = (controls.count + perRow - 1) / perRow
            let top = size.height - m.margin - length(lines)
            for (index, control) in controls.enumerated() {
                let line = index / perRow
                let inLine = min(perRow, controls.count - line * perRow)
                frames[control] = CGRect(x: size.width - m.margin - length(inLine) + CGFloat(index % perRow) * (m.button + m.gap),
                                         y: top + CGFloat(line) * (m.button + m.gap), width: m.button, height: m.button)
            }
        }
        // No stack (the phone showing a leg): a point at the foot of the right edge, so what is placed
        // beside it takes the chart's width.
        let stack = frames.isEmpty
            ? CGRect(x: size.width - m.margin, y: size.height - m.margin, width: 0, height: 0)
            : frames.values.reduce(CGRect.null) { $0.union($1) }

        // The slot at the top left: beside the stack where they share rows, else as wide as it may be.
        let besideStack = max(0, stack.minX - m.slotGap - m.margin)
        let sharesRows = stack.minY < m.margin + m.slotHeight + m.slotGap
        let room = sharesRows ? besideStack : size.width - 2 * m.margin
        let slot = CGRect(x: m.margin, y: m.margin, width: min(m.slotWidth, room), height: m.slotHeight)

        // What the foot keeps for itself: the margin, or a leg's bar and a gap over it.
        let floor = footRoom > 0 ? size.height - footRoom - m.gap : size.height - m.margin

        // The scale at the foot, left; over the stack's row where a row reaches it (a short phone chart),
        // over a leg's bar where one shows.
        var scaleFrame = CGRect(x: m.margin, y: floor - m.scaleSize.height,
                                width: m.scaleSize.width, height: m.scaleSize.height)
        if !frames.isEmpty, scaleFrame.intersects(stack) {
            scaleFrame.origin.y = min(stack.minY, floor) - m.gap - m.scaleSize.height
        }

        // The arrow: left of the stack, or above it, whichever leaves it more room; over a leg's bar.
        let below = slot.maxY + m.slotGap
        let left = CGRect(x: m.margin, y: below, width: besideStack, height: max(0, floor - below))
        let above = CGRect(x: m.margin, y: below, width: max(0, size.width - 2 * m.margin),
                           height: max(0, min(stack.minY - m.slotGap, floor) - below))

        self.size = size
        self.metrics = m
        self.controls = controls
        self.frames = frames
        self.isColumn = isColumn
        self.stack = stack
        self.statusSlot = slot
        self.scale = scaleFrame
        self.arrowBounds = left.width * left.height >= above.width * above.height ? left : above
        self.footRoom = footRoom
    }

    /// What a leg's bar takes of the foot: its height and the stack's margin under it.
    let footRoom: CGFloat

    /// A leg's bar from ROUTE (`FramedLegBar`) along the chart's foot: from the left margin to the stack
    /// (a gap short of it), or to the right margin without one, on the stack's margin. `height`: the bar's.
    func legBarFrame(height: CGFloat) -> CGRect {
        let right = frames.isEmpty ? size.width - metrics.margin : stack.minX - metrics.gap
        return CGRect(x: metrics.margin, y: size.height - metrics.margin - height,
                      width: max(0, right - metrics.margin), height: height)
    }

    /// The chrome around what MAP frames (the aircraft and its leg after OFF ROUTE, a leg from ROUTE): the
    /// slot when a state shows, the stack (a column takes the right, a row the foot), a leg's bar. The
    /// caller adds its breathing room and its caps (`LegFraming.edgePadding(chartSize:chrome:)`).
    func framingChrome(statusShown: Bool) -> UIEdgeInsets {
        let hasStack = !frames.isEmpty
        let top = statusShown ? statusSlot.maxY : 0
        let right = hasStack && isColumn ? size.width - stack.minX : 0
        let stackFoot = hasStack && !isColumn ? size.height - stack.minY : 0
        let barFoot = footRoom > 0 ? footRoom : 0
        return UIEdgeInsets(top: top, left: 0, bottom: max(stackFoot, barFoot), right: right)
    }

    func frame(_ control: Control) -> CGRect {
        frames[control] ?? .zero
    }

    /// The edge arrow for the aircraft at `point` on the chart (it may lie off it), or nil while it can
    /// be seen: on the chart, not under a control. The arrow sits where the ray from the middle of
    /// `arrowBounds` to the aircraft leaves them, so pointing along that ray it points at the aircraft,
    /// and it never covers the stack or the slot.
    func edgeArrow(toward point: CGPoint) -> OwnshipEdgeArrow.Placement? {
        let half = metrics.arrowSize / 2
        let onChart = CGRect(origin: .zero, size: size).insetBy(dx: half, dy: half).contains(point)
        guard !onChart || frames.values.contains(where: { $0.contains(point) }) else { return nil }
        let local = CGPoint(x: point.x - arrowBounds.minX, y: point.y - arrowBounds.minY)
        guard let placed = OwnshipEdgeArrow.place(screenPoint: local, size: arrowBounds.size, inset: half) else { return nil }
        return OwnshipEdgeArrow.Placement(point: CGPoint(x: placed.point.x + arrowBounds.minX,
                                                         y: placed.point.y + arrowBounds.minY),
                                          degrees: placed.degrees)
    }

    /// The chart the chrome covers, in square points: the controls, and the slot while a state shows.
    /// The edge arrow and the scale come and go, small, and are left out.
    func coveredArea(statusShown: Bool) -> CGFloat {
        let controls = frames.values.reduce(0) { $0 + $1.width * $1.height }
        return controls + (statusShown ? statusSlot.width * statusSlot.height : 0)
    }

    /// The share of the chart left free, 0…1.
    func freeFraction(statusShown: Bool) -> Double {
        let area = size.width * size.height
        guard area > 0 else { return 0 }
        return Double(1 - coveredArea(statusShown: statusShown) / area)
    }
}

/// Each placed piece, for the tests' frames.
enum MapChromeElement: Hashable {
    case control(MapChromeGeometry.Control)
    case status
    case edgeArrow
    case scale

    /// The chrome's coordinate space: the chart's.
    static let space = "mapChrome"
}

// MARK: - The chrome

/// The chrome over the Cockpit's chart. An overlay the size of the chart: it catches no touch outside
/// its pieces, so the chart pans and pinches under it.
struct CockpitMapChrome: View {
    let model: MapChromeModel
    let actions: MapChromeActions
    /// The device's measures; the tests lay the phone's out on an iPad.
    var scale: CockpitScale = .current
    /// The language the chrome reads in, "fr"; nil, the app's. For the French previews and tests.
    var language: String? = nil
    /// The scale shown or hidden whatever the zoom does: previews and renders. Nil: it follows the zoom.
    var scaleShownOverride: Bool? = nil
    /// For the tests: each piece as laid out, in the chart's coordinates.
    var onPlace: ((MapChromeElement, CGRect) -> Void)? = nil
    /// False while the phone shows a leg from ROUTE (`MapChromeGeometry`'s).
    var showsStack = true
    /// What a leg's bar takes of the chart's foot (`MapChromeGeometry`'s).
    var footRoom: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scaleVisibility = ScaleVisibility()
    @State private var scaleShown = false
    /// When the chrome came: the map sets its camera in the moments after (the zoom it was left at), which
    /// is no zoom of the pilot's.
    @State private var appearedAt = Date()

    /// How long after appearing the map's own camera settles: its zoom shows no scale.
    static let settling: TimeInterval = 1

    var body: some View {
        GeometryReader { proxy in
            pieces(MapChromeGeometry(size: proxy.size, scale: scale, showsStack: showsStack, footRoom: footRoom))
        }
        .coordinateSpace(.named(MapChromeElement.space))
        .onAppear {
            appearedAt = Date()
            scaleVisibility.note(zoom: model.zoom)
        }
        .onChange(of: model.zoom) { _, zoom in noteZoom(zoom) }
        .task(id: scaleVisibility.changedAt) { await hideScaleLater() }
    }

    private func pieces(_ geometry: MapChromeGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(geometry.controls, id: \.self) { control in
                MapChromeControlButton(control: control, model: model, actions: actions,
                                       metrics: geometry.metrics, language: language)
                    .modifier(MapChromePlacement(element: .control(control), frame: geometry.frame(control),
                                                 onPlace: onPlace))
            }
            if let status = model.status {
                MapStatusSlot(status: status, undoOffer: model.undoOffer, actions: actions,
                              metrics: geometry.metrics, language: language)
                    .modifier(MapChromePlacement(element: .status, frame: geometry.statusSlot, onPlace: onPlace))
                    .transition(.opacity)
            }
            if let arrow = edgeArrow(geometry) {
                MapChromeEdgeArrow(degrees: arrow.degrees, size: geometry.metrics.arrowSize, language: language)
                    .modifier(MapChromePlacement(element: .edgeArrow, frame: arrowFrame(arrow, geometry),
                                                 onPlace: onPlace))
            }
            if scaleShownOverride ?? scaleShown {
                SwissScaleBar(region: model.region, mapWidth: geometry.size.width, nauticalMiles: model.nauticalMiles)
                    .frame(width: geometry.scale.width, height: geometry.scale.height, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("map.scale")
                    .modifier(MapChromePlacement(element: .scale, frame: geometry.scale, onPlace: onPlace))
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.status)
    }

    private func edgeArrow(_ geometry: MapChromeGeometry) -> OwnshipEdgeArrow.Placement? {
        guard !model.isFollowingAircraft, let aircraft = model.aircraft,
              let point = OwnshipEdgeArrow.project(aircraft, region: model.region, heading: model.heading,
                                                   size: geometry.size) else { return nil }
        return geometry.edgeArrow(toward: point)
    }

    private func arrowFrame(_ arrow: OwnshipEdgeArrow.Placement, _ geometry: MapChromeGeometry) -> CGRect {
        let side = geometry.metrics.arrowSize
        return CGRect(x: arrow.point.x - side / 2, y: arrow.point.y - side / 2, width: side, height: side)
    }

    // MARK: The scale

    /// A change of zoom shows the scale; following the aircraft changes none, nor does the map setting its
    /// camera as MAP appears (the zoom becomes the reference then).
    private func noteZoom(_ zoom: Double) {
        guard Date().timeIntervalSince(appearedAt) >= Self.settling else {
            scaleVisibility = ScaleVisibility()
            scaleVisibility.note(zoom: zoom)
            return
        }
        let before = scaleVisibility.changedAt
        scaleVisibility.note(zoom: zoom)
        guard scaleVisibility.changedAt != before else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { scaleShown = true }
    }

    /// Two seconds after the last change, the scale goes: a fade, or at once with Reduce Motion. The
    /// pilot's two seconds, as the undo's six are, whatever pace a replay runs the flight at. A newer
    /// change restarts this task.
    private func hideScaleLater() async {
        guard scaleVisibility.changedAt != nil else { return }
        try? await Task.sleep(for: .seconds(ScaleVisibility.shownFor))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { scaleShown = false }
    }
}

/// A piece at its frame in the chart, and, for the tests, the frame it was laid out at.
private struct MapChromePlacement: ViewModifier {
    let element: MapChromeElement
    let frame: CGRect
    let onPlace: ((MapChromeElement, CGRect) -> Void)?

    func body(content: Content) -> some View {
        content
            .frame(width: frame.width, height: frame.height)
            .background {
                if let onPlace {
                    GeometryReader { proxy in
                        let _ = onPlace(element, proxy.frame(in: .named(MapChromeElement.space)))
                        Color.clear
                    }
                }
            }
            .position(x: frame.midX, y: frame.midY)
    }
}

// MARK: - The stack

/// One control of the stack: a square, its glyph in the colour of what can be touched, filled where it is
/// the one that matters (centre, once panned). Its name is for VoiceOver; its value, for the UI tests.
struct MapChromeControlButton: View {
    let control: MapChromeGeometry.Control
    let model: MapChromeModel
    let actions: MapChromeActions
    let metrics: MapChromeGeometry.Metrics
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        Button(action: action) { face }
            .buttonStyle(.plain)
            .accessibilityLabel(MapChromeControlButton.label(control, model: model, language: language))
            .accessibilityValue(MapChromeControlButton.value(control, model: model, language: language))
            .accessibilityIdentifier(MapChromeControlButton.identifier(control))
    }

    private var prominent: Bool { control == .centre && !model.isFollowingAircraft }

    private var face: some View {
        glyph
            .foregroundColor(prominent ? theme.actionText : theme.action)
            .frame(width: metrics.button, height: metrics.button)
            .background(RoundedRectangle(cornerRadius: metrics.cornerRadius).fill(prominent ? theme.action : theme.panel))
            .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .strokeBorder(prominent ? Color.clear : theme.panelStroke, lineWidth: 1))
            .overlay(alignment: .topTrailing) { staleBadge }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyph: some View {
        switch control {
        case .orientation:
            // N↑ or TRK, the mode the chart is in.
            Text(verbatim: model.orientation == .northUp ? "N↑" : "TRK")
                .font(.aero(size: metrics.orientationTextSize, weight: .bold))
                .lineLimit(1)
        default:
            Image(systemName: MapChromeControlButton.icon(control, model: model))
                .font(.aero(size: metrics.controlIconSize, weight: .semibold))
        }
    }

    /// The airspace data aging or stale: the cue sits on the button that leads to it, as on the map's row.
    @ViewBuilder
    private var staleBadge: some View {
        if control == .layers && model.airspaceNeedsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.aero(size: 14, weight: .bold))
                .foregroundColor(theme.warning)
                .padding(4)
                .background(theme.panel, in: Circle())
                .offset(x: 8, y: -8)
                .accessibilityHidden(true)
        }
    }

    private func action() {
        switch control {
        case .orientation: actions.toggleOrientation()
        case .layers: actions.showLayers()
        case .centre: actions.centre()
        case .zoomIn: actions.zoomIn()
        case .zoomOut: actions.zoomOut()
        }
    }

    static func icon(_ control: MapChromeGeometry.Control, model: MapChromeModel) -> String {
        switch control {
        case .orientation: return "location.north.line"
        case .layers: return "square.stack.3d.up"
        case .centre: return model.isFollowingAircraft ? "location" : "location.fill"
        case .zoomIn: return "plus"
        case .zoomOut: return "minus"
        }
    }

    static func identifier(_ control: MapChromeGeometry.Control) -> String {
        switch control {
        case .orientation: return "map.orientation"
        case .layers: return "map.layers"
        case .centre: return "map.centre"
        case .zoomIn: return "map.zoomIn"
        case .zoomOut: return "map.zoomOut"
        }
    }

    /// The control's name: the orientation by the mode it shows, as the phone's button reads today.
    static func label(_ control: MapChromeGeometry.Control, model: MapChromeModel, language: String?) -> String {
        switch control {
        case .orientation:
            return model.orientation == .northUp ? L10n.MapChrome.northUp(language: language)
                                                 : L10n.MapChrome.trackUp(language: language)
        case .layers: return L10n.MapChrome.layers(language: language)
        case .centre: return L10n.MapChrome.centre(language: language)
        case .zoomIn: return L10n.MapChrome.zoomIn(language: language)
        case .zoomOut: return L10n.MapChrome.zoomOut(language: language)
        }
    }

    /// What the UI tests read (plan §6): northUp / trackUp, following / panned; the layers' stale data.
    static func value(_ control: MapChromeGeometry.Control, model: MapChromeModel, language: String?) -> String {
        switch control {
        case .orientation: return model.orientation == .northUp ? "northUp" : "trackUp"
        case .centre: return model.isFollowingAircraft ? "following" : "panned"
        case .layers: return model.airspaceNeedsAttention ? L10n.MapChrome.airspaceStale(language: language) : ""
        case .zoomIn, .zoomOut: return ""
        }
    }
}

// MARK: - The edge arrow

/// The arrow at the chart's edge pointing to the aircraft, once panned away from it. An indicator, not a
/// button: centre, filled meanwhile, brings the aircraft back. Read as a clock position from the top.
struct MapChromeEdgeArrow: View {
    let degrees: Double
    let size: CGFloat
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.aero(size: size * 0.46, weight: .bold))
            .foregroundColor(theme.textPrimary)
            .rotationEffect(.degrees(degrees))
            .frame(width: size, height: size)
            .background(Circle().fill(theme.panel.opacity(0.94)))
            .overlay(Circle().strokeBorder(theme.panelStroke, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(L10n.MapChrome.aircraftOffScreen(clock: Self.clock(degrees), language: language))
            .accessibilityIdentifier("map.edgeArrow")
    }

    /// The direction as a clock position from the top of the screen: 0° is 12, 90° is 3.
    static func clock(_ degrees: Double) -> Int {
        guard degrees.isFinite else { return 12 }
        let hour = Int((degrees / 30).rounded()) % 12
        return hour <= 0 ? hour + 12 : hour
    }
}

// MARK: - The status slot

/// The slot at the top left: the state `CockpitStatusRule` picks, at one size whatever it is. UNDO is
/// the message and its button; the others are one button each, a tap away from what they are about.
struct MapStatusSlot: View {
    let status: CockpitStatus
    let undoOffer: NavUndoOffer?
    let actions: MapChromeActions
    let metrics: MapChromeGeometry.Metrics
    var language: String? = nil

    var body: some View {
        if case .undo = status {
            if let offer = undoOffer {
                MapUndoSlot(offer: offer, metrics: metrics, language: language) { actions.dismissUndo(offer) }
                    .id(offer.id)
            }
        } else {
            MapStatusButton(status: status, metrics: metrics, language: language) { actions.openStatus(status) }
        }
    }
}

/// A state other than UNDO: its icon, its words in the state's colour, the whole slot the target.
struct MapStatusButton: View {
    let status: CockpitStatus
    let metrics: MapChromeGeometry.Metrics
    var language: String? = nil
    let action: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let colors = MapStatusColors(status.tone, theme: theme)
        let shape = RoundedRectangle(cornerRadius: metrics.slotCornerRadius)
        Button(action: action) {
            MapStatusFace(status: status, metrics: metrics, language: language)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(shape.fill(colors.fill))
                .overlay(shape.strokeBorder(colors.border, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MapStatusText.spoken(status, language: language))
        .accessibilityHint(MapStatusText.hint(status, language: language))
        .accessibilityIdentifier(status.accessibilityIdentifier)
    }
}

/// A state's face: the icon in a fixed column, the title on one line, its detail under it.
/// `unlimitedLines`: the tests measure what the words need, with nothing cut.
struct MapStatusFace: View {
    let status: CockpitStatus
    let metrics: MapChromeGeometry.Metrics
    var language: String? = nil
    var unlimitedLines = false

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let colors = MapStatusColors(status.tone, theme: theme)
        HStack(spacing: metrics.statusIconGap) {
            Image(systemName: MapStatusText.icon(status))
                .font(.aero(size: metrics.statusIconSize, weight: .bold))
                .foregroundColor(colors.accent)
                .frame(width: metrics.statusIconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: MapStatusText.title(status, language: language))
                    .font(.aero(size: metrics.textSize, weight: .bold))
                    .foregroundColor(colors.accent)
                    .lineLimit(unlimitedLines ? nil : 1)
                if let detail = MapStatusText.detail(status, language: language) {
                    Text(verbatim: detail)
                        .font(.aero(size: metrics.textSize))
                        .foregroundColor(colors.text)
                        .lineLimit(unlimitedLines ? nil : 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, metrics.slotPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The width the words have in a slot `slotWidth` wide.
    static func textWidth(slotWidth: CGFloat, metrics: MapChromeGeometry.Metrics) -> CGFloat {
        slotWidth - 2 * metrics.slotPadding - metrics.statusIconColumn - metrics.statusIconGap
    }
}

/// The in-flight colour contract: amber for a caution on the panel, red filled for NO GPS, cyan for
/// BRIEFING (touchable, nothing wrong), the panel for UNDO.
struct MapStatusColors {
    let fill: Color
    let border: Color
    let accent: Color
    let text: Color

    init(_ tone: CockpitStatus.Tone, theme: CockpitTheme) {
        switch tone {
        case .neutral:
            fill = theme.panel.opacity(0.97); border = theme.panelStroke; accent = theme.textPrimary; text = theme.textPrimary
        case .caution:
            fill = theme.panel.opacity(0.97); border = theme.warning; accent = theme.warning; text = theme.textPrimary
        case .warning:
            fill = theme.danger; border = theme.danger; accent = .white; text = .white
        case .action:
            fill = theme.panel.opacity(0.97); border = theme.action; accent = theme.action; text = theme.textPrimary
        }
    }
}

/// What each state says.
enum MapStatusText {
    static func title(_ status: CockpitStatus, language: String?) -> String {
        switch status {
        case .undo: return L10n.MapChrome.undo(language: language).uppercased()
        case .gps(.degraded): return L10n.MapChrome.gpsDegraded(language: language)
        case .gps(.lost): return L10n.MapChrome.noGPS(language: language)
        case .offRoute(let nm): return L10n.MapChrome.offRoute(distance(nm), language: language)
        case .chartOffline: return L10n.MapChrome.chartOffline(language: language)
        case .tellFIS: return L10n.MapChrome.tellFIS(language: language)
        case .sigmet: return "SIGMET"
        // As the chip said it, in English in French too.
        case .briefing: return "BRIEFING"
        }
    }

    /// The line under the title: the field diverted to, the SIGMET's hazard and where it is.
    static func detail(_ status: CockpitStatus, language: String?) -> String? {
        switch status {
        case .tellFIS(let field): return L10n.MapChrome.divertingTo(field, language: language)
        case .sigmet(let summary): return summary.isEmpty ? nil : summary
        default: return nil
        }
    }

    static func spoken(_ status: CockpitStatus, language: String?) -> String {
        [title(status, language: language), detail(status, language: language)].compactMap { $0 }.joined(separator: ", ")
    }

    static func hint(_ status: CockpitStatus, language: String?) -> String {
        switch status {
        case .undo: return ""
        case .gps: return L10n.MapChrome.gpsHint(language: language)
        case .offRoute: return L10n.MapChrome.offRouteHint(language: language)
        case .chartOffline: return L10n.MapChrome.chartOfflineHint(language: language)
        case .tellFIS: return L10n.MapChrome.tellFISHint(language: language)
        case .sigmet: return L10n.MapChrome.sigmetHint(language: language)
        case .briefing: return L10n.MapChrome.briefingHint(language: language)
        }
    }

    static func icon(_ status: CockpitStatus) -> String {
        switch status {
        case .undo: return "arrow.uturn.backward"
        // Not the centre button's arrow: a fix, then no fix.
        case .gps(.degraded): return "scope"
        case .gps(.lost): return "location.slash.fill"
        case .offRoute: return "arrow.left.and.right"
        case .chartOffline: return "wifi.slash"
        case .tellFIS: return "antenna.radiowaves.left.and.right"
        case .sigmet: return "exclamationmark.triangle.fill"
        case .briefing(let type): return type == .departure ? "airplane.departure" : "airplane.arrival"
        }
    }

    /// The cross-track distance as the map writes distances: "1.2", then whole miles from 10.
    static func distance(_ nauticalMiles: Double) -> String {
        guard nauticalMiles.isFinite else { return "—" }
        return nauticalMiles < 9.95 ? String(format: "%.1f", nauticalMiles) : String(format: "%.0f", nauticalMiles)
    }
}

// MARK: - UNDO in the slot

/// The six seconds of an undo offer, as a share left.
enum UndoCountdown {
    /// The offer's (`UndoOfferRule`), as `AppState.memoryConfirmationUndoWindow`.
    static let window: TimeInterval = UndoOfferRule.window

    /// 1 when offered, 0 once over.
    static func remaining(elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite else { return 0 }
        return min(max(1 - elapsed / window, 0), 1)
    }
}

/// UNDO in the slot: the message, and UNDO with its six seconds running out under the word. It goes on
/// its own when they are up, as the toast does; VoiceOver hears the message when it comes. The six
/// seconds are the offer's, from when it was made (`UndoOfferRule`): coming back to MAP shows what is left
/// of them. (6.2)
struct MapUndoSlot: View {
    let offer: NavUndoOffer
    let metrics: MapChromeGeometry.Metrics
    var language: String? = nil
    let onDismiss: () -> Void

    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.slotCornerRadius)
        MapUndoFace(message: offer.message, style: offer.style, shownAt: offer.madeAt, metrics: metrics, language: language) {
            offer.undo()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { onDismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(theme.panel.opacity(0.97)))
        .overlay(shape.strokeBorder(theme.panelStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status.undo")
        .modifier(UndoOfferExpiry(offer: offer, onDismiss: onDismiss))
    }
}

/// UNDO's face: the message at the left, on as many lines as it needs up to the slot's height; UNDO at
/// the right, as tall as the slot. Filled for the pilot's own tap (MARK, the leg-timer reset), outlined
/// for what the flight did on its own, as the toast drew them.
struct MapUndoFace: View {
    let message: String
    let style: NavUndoToast.Style
    /// When the offer showed, for the countdown; nil, a full bar.
    var shownAt: Date? = nil
    let metrics: MapChromeGeometry.Metrics
    var language: String? = nil
    var unlimitedLines = false
    let onUndo: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.statusIconGap) {
            Text(message)
                .font(.aero(size: metrics.textSize, weight: .semibold))
                .foregroundColor(theme.textPrimary)
                .lineLimit(unlimitedLines ? nil : metrics.undoMessageLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("undoToast.message")
            Button(action: onUndo) { undoLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.MapChrome.undo(language: language))
                .accessibilityIdentifier("undoToast.undo")
        }
        .padding(.leading, metrics.slotPadding)
    }

    private var undoLabel: some View {
        let filled = style == .filled
        let shape = RoundedRectangle(cornerRadius: metrics.slotCornerRadius)
        return Text(verbatim: L10n.MapChrome.undo(language: language).uppercased())
            .font(.aero(size: metrics.textSize, weight: .heavy))
            .lineLimit(1)
            .foregroundColor(filled ? theme.actionText : theme.action)
            .frame(width: metrics.undoButtonWidth)
            .frame(minHeight: metrics.slotHeight)
            .background { if filled { shape.fill(theme.action) } }
            .overlay { if !filled { shape.strokeBorder(theme.action, lineWidth: 2) } }
            .overlay(alignment: .bottomLeading) {
                UndoCountdownBar(shownAt: shownAt, width: metrics.undoButtonWidth - 28,
                                 color: (filled ? theme.actionText : theme.action).opacity(0.6))
                    .padding(.leading, 14)
                    .padding(.bottom, 9)
            }
            .contentShape(Rectangle())
    }

    /// The width the message has in a slot `slotWidth` wide.
    static func messageWidth(slotWidth: CGFloat, metrics: MapChromeGeometry.Metrics) -> CGFloat {
        slotWidth - metrics.slotPadding - metrics.statusIconGap - metrics.undoButtonWidth
    }
}

/// The undo's seconds running out: a bar that shortens, smoothly, or by the second with Reduce Motion.
struct UndoCountdownBar: View {
    let shownAt: Date?
    let width: CGFloat
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.1)) { _ in
            let left = shownAt.map { UndoCountdown.remaining(elapsed: FlightClock.pilotSeconds(since: $0)) } ?? 1
            Capsule()
                .fill(color)
                .frame(width: max(0, width * CGFloat(left)), height: 4)
                .frame(width: width, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - On the Cockpit's chart (6.2, PR 4)
//
// The chrome above draws plain values. What follows gathers them from the flight: `CockpitChartChrome` on
// the map (the status slot's inputs, the undo offer and its dismissal), `CockpitMapState` and its
// follower on the Cockpit's frame (OFF ROUTE, fed every fix on every page), and More's two items for the
// chart.

/// What the Cockpit's chart shares with the rest of the Cockpit, on every page: OFF ROUTE, followed every
/// fix whatever page shows (a rule fed only while MAP shows would start from scratch each time MAP came
/// back, and say nothing until the aircraft rejoined the route), the SIGMETs in range for More, and
/// More's requests to the chart. The Cockpit's, put in the environment by `FlightView`; Plan › Map has none.
@MainActor
@Observable
final class CockpitMapState {
    /// OFF ROUTE's cross-track distance, to the tenth of a mile; nil while on the route or dark.
    private(set) var offRouteNM: Double?
    /// The SIGMETs in range: More's "Hazards (n)".
    var hazardCount = 0
    /// More's "Show the whole route" and "Hazards (n)": bumped, MAP acts on the change.
    private(set) var wholeRouteRequest = 0
    private(set) var hazardsRequest = 0

    @ObservationIgnored private var offRoute = OffRouteRule()

    /// One fix, or a change of the plan or the flight: OFF ROUTE as the rule now says it.
    func note(_ input: OffRouteRule.Input) {
        let shown = offRoute.update(input).map { ($0 * 10).rounded() / 10 }
        if shown != offRouteNM { offRouteNM = shown }
    }

    func showWholeRoute() { wholeRouteRequest &+= 1 }
    func showHazards() { hazardsRequest &+= 1 }
}

/// Keeps `CockpitMapState` current on every page: OFF ROUTE on every fix and on every change of the plan
/// or the flight that can start or stop it, and the SIGMETs' count. On the Cockpit's frame, beside
/// `CockpitRadioFollower`.
struct CockpitMapFollower: ViewModifier {
    let mapState: CockpitMapState

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var aviationWeatherService: AviationWeatherService

    /// What OFF ROUTE is evaluated again for, besides a fix.
    struct Key: Equatable {
        let target: Int?
        let waypointCount: Int
        let diversion: String?
        let circuits: Bool
        let linedUp: Bool
        let landed: Bool
        let tracking: Bool
        let signal: GPSSignalStatus
        let simulating: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                note()
                mapState.hazardCount = aviationWeatherService.sigmets.count
            }
            .onChange(of: locationManager.currentLocation) { _, _ in note() }
            .onChange(of: key) { _, _ in note() }
            .onChange(of: aviationWeatherService.sigmets.count) { _, count in mapState.hazardCount = count }
    }

    private var key: Key {
        let plan = flightPlanManager.activeFlightPlan
        return Key(target: plan?.currentWaypointIndex, waypointCount: plan?.waypoints.count ?? 0,
                   diversion: plan?.diversion?.ident, circuits: appState.isCircuitMode,
                   linedUp: appState.lineUpTime != nil, landed: appState.landingTime != nil,
                   tracking: locationManager.isTracking, signal: locationManager.gpsSignalStatus,
                   simulating: locationManager.isSimulatingPosition)
    }

    private func note() {
        mapState.note(OffRouteRule.Input(
            plan: flightPlanManager.activeFlightPlan, aircraft: locationManager.currentLocation?.coordinate,
            circuits: appState.isCircuitMode, lineUpTime: appState.lineUpTime, landingTime: appState.landingTime,
            isTracking: locationManager.isTracking, signal: locationManager.gpsSignalStatus,
            isSimulating: locationManager.isSimulatingPosition))
    }
}

/// Whether the status slot shows a state, for the map's framing (a leg, the aircraft and its leg).
struct MapStatusShownKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The chrome over the Cockpit's chart, wired. The map hands it what only the map knows (its
/// orientation, whether it follows the aircraft, its region, the SIGMETs it ranked, its taps); it reads
/// the flight for the status slot, and owns the undo offer's dismissal, as the map's undo toast did. A
/// view of its own, so the map's body only places it.
struct CockpitChartChrome: View {
    @ObservedObject var mapState: SharedMapState
    /// `dataStatusManager.networkMonitor`, observed here: CHART OFFLINE follows the network (plan §5.2).
    @ObservedObject var networkMonitor: NetworkMonitor
    let orientation: MapOrientationMode
    let isFollowingAircraft: Bool
    let airspaceNeedsAttention: Bool
    let selectedLayer: MapLayerType
    /// `NavigationMapView.rankedSigmets`: the one on the aircraft's path is the slot's.
    let sigmets: [SigmetHazardItem]
    var showsStack = true
    var footRoom: CGFloat = 0
    /// Every tap but UNDO's dismissal, which is this view's.
    let actions: MapChromeActions

    @Environment(AppState.self) private var appState
    @Environment(CockpitNavState.self) private var cockpitNav: CockpitNavState?
    @Environment(CockpitMapState.self) private var cockpitMap: CockpitMapState?
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var offlineMapManager: OfflineMapManager
    @EnvironmentObject private var threadManager: FlightThreadManager

    var body: some View {
        let undo = NavUndoOffer.shown(in: appState, flightPlanManager: flightPlanManager,
                                      cockpitNav: cockpitNav, flightOnly: true)
        let status = shownStatus(undoOffered: undo != nil)
        CockpitMapChrome(
            model: MapChromeModel(orientation: orientation, isFollowingAircraft: isFollowingAircraft,
                                  airspaceNeedsAttention: airspaceNeedsAttention, status: status, undoOffer: undo,
                                  region: mapState.region,
                                  heading: orientation == .trackUp ? mapState.cameraHeading : 0,
                                  aircraft: locationManager.currentLocation?.coordinate,
                                  zoom: mapState.cameraDistance,
                                  nauticalMiles: appState.settings.distanceInNauticalMiles),
            actions: wiredActions, showsStack: showsStack, footRoom: footRoom)
            // A waypoint the flight marked, or a check just confirmed, withdraws the band's older offer.
            .modifier(UndoOfferFollower(cockpitNav: cockpitNav))
            .preference(key: MapStatusShownKey.self, value: status != nil)
    }

    /// The state the slot shows: UNDO first, then what the flight says (plan §5.1).
    private func shownStatus(undoOffered: Bool) -> CockpitStatus? {
        #if DEBUG
        // The captures' (6.2): `AEROCHECK_STATUS=gps|nogps|offroute|chartoffline|tellfis|sigmet|briefing`
        // holds the slot on that state, under UNDO.
        if !undoOffered, let held = Self.capturedStatus { return held }
        #endif
        return CockpitStatusRule.current(statusInputs(undoOffered: undoOffered))
    }

    /// The slot's inputs, from the flight.
    private func statusInputs(undoOffered: Bool) -> CockpitStatusRule.Inputs {
        let plan = flightPlanManager.activeFlightPlan
        let filed = plan.flatMap { threadManager.thread(forPlanId: $0.id) }?.hasOpenFlightPlan ?? false
        return CockpitStatusRule.Inputs(
            undoOffered: undoOffered,
            gps: CockpitStatusRule.gpsAlarm(isFlightActive: appState.isFlightActive,
                                            isTracking: locationManager.isTracking,
                                            signal: locationManager.gpsSignalStatus,
                                            isSimulating: locationManager.isSimulatingPosition),
            offRouteNM: cockpitMap?.offRouteNM,
            chartOffline: ChartAvailability.isChartOffline(chartInput),
            tellFISField: CockpitStatusRule.tellFIS(diversionIdent: plan?.diversion?.ident, hasOpenATCFlightPlan: filed),
            sigmetOnPath: CockpitStatusRule.sigmetOnPath(sigmets).map(Self.sigmetSummary),
            briefing: appState.currentPhase.briefingType)
    }

    /// CHART OFFLINE's inputs: the chart picked, the network, the caches, the zoom and the region.
    private var chartInput: ChartAvailability.Input {
        ChartAvailability.Input(selectedLayer: selectedLayer, offlineMode: appState.settings.offlineMode,
                                isConnected: networkMonitor.isConnected,
                                icaoCached: offlineMapManager.isCacheAvailable,
                                gliderCached: offlineMapManager.isSegelflugCacheAvailable,
                                forceICAOChartLayer: appState.settings.forceICAOChartLayer,
                                zoom: ChartAvailability.zoom(latitudeDelta: mapState.region.span.latitudeDelta),
                                region: mapState.region)
    }

    /// "SEV TURB · on route", as the SIGMET sheet names a hazard and where it is.
    static func sigmetSummary(_ item: SigmetHazardItem) -> String {
        "\(SigmetFormat.hazardName(item.sigmet)) \(SigmetFormat.proximity(item))"
    }

    /// UNDO's dismissal, as the toast's: the band's offer cleared, the flight's notice and the check's
    /// confirmation dismissed.
    private var wiredActions: MapChromeActions {
        var wired = actions
        let cockpitNav = cockpitNav
        let flightPlanManager = flightPlanManager
        let appState = appState
        wired.dismissUndo = { offer in
            if offer.id == cockpitNav?.undoOffer?.id { cockpitNav?.undoOffer = nil }
            flightPlanManager.dismissAutoMarkNotice(offer.id)
            appState.dismissCheckConfirmation(offer.id)
        }
        return wired
    }

    #if DEBUG
    private static let capturedStatus: CockpitStatus? = {
        switch ProcessInfo.processInfo.environment["AEROCHECK_STATUS"]?.lowercased() {
        case "gps": return .gps(.degraded)
        case "nogps": return .gps(.lost)
        case "offroute": return .offRoute(crossTrackNM: 1.4)
        case "chartoffline": return .chartOffline
        case "tellfis": return .tellFIS(field: "LSGC")
        case "sigmet": return .sigmet(summary: "SEV TURB · " + L10n.Nav.sigmetOnRoute)
        case "briefing": return .briefing(.approach)
        default: return nil
        }
    }()
    #endif
}

/// More's items for the chart, on MAP: the SIGMETs, whose chip left the chart ("Hazards (2)"; the one on
/// the aircraft's path is in the status slot too), and the whole route, which the off-screen route's pill
/// showed. OFF ROUTE and the edge arrow say the rest of what the pill said.
struct CockpitMapMoreItems: View {
    @Environment(CockpitMapState.self) private var cockpitMap: CockpitMapState?
    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    var body: some View {
        if let cockpitMap {
            if cockpitMap.hazardCount > 0 {
                Button { cockpitMap.showHazards() } label: {
                    Label(L10n.MapChrome.hazards(cockpitMap.hazardCount), systemImage: "exclamationmark.triangle")
                }
            }
            if (flightPlanManager.activeFlightPlan?.waypoints.count ?? 0) >= 2 {
                Button { cockpitMap.showWholeRoute() } label: {
                    Label(L10n.MapChrome.wholeRoute(), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
/// The previews' and the tests' chrome: the proposal's route near Grenchen, a chart of the Cockpit's size
/// on each device, every state in English and French.
enum MapChromeSample {
    /// The chart's room on each device once the read band carries NOW | NEXT (plan PR 3), from the act
    /// band's renders (#298): an iPad Air 11" in portrait and on its side, a 6.1" iPhone (17e).
    enum Chart: String, CaseIterable {
        case iPadPortrait = "ipad-portrait"
        case iPadLandscape = "ipad-landscape"
        case phone = "phone"

        var size: CGSize {
            switch self {
            case .iPadPortrait: return CGSize(width: 820, height: 560)
            case .iPadLandscape: return CGSize(width: 1180, height: 270)
            case .phone: return CGSize(width: 390, height: 256)
            }
        }

        var scale: CockpitScale { self == .phone ? .phone : .kneeboard }
    }

    static let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47.18, longitude: 7.42),
                                           span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.35))
    /// North-east of the chart, off it: where the edge arrow points once panned.
    static let aircraftOffChart = CLLocationCoordinate2D(latitude: 47.45, longitude: 7.85)

    static func model(status: CockpitStatus? = nil, undo: NavUndoOffer? = nil, panned: Bool = false,
                      orientation: MapOrientationMode = .northUp, stale: Bool = false) -> MapChromeModel {
        MapChromeModel(orientation: orientation, isFollowingAircraft: !panned, airspaceNeedsAttention: stale,
                       status: status, undoOffer: undo, region: region,
                       heading: orientation == .northUp ? 0 : 211,
                       aircraft: panned ? aircraftOffChart : region.center, zoom: 40_000)
    }

    /// The states, with their names; UNDO with the longest message of its kind.
    static func states(language: String) -> [(name: String, status: CockpitStatus, undo: NavUndoOffer?)] {
        [("undo-mark", .undo, undoOffer(.mark, language: language)),
         ("undo-auto", .undo, undoOffer(.automatic, language: language)),
         ("gps-degraded", .gps(.degraded), nil),
         ("gps-lost", .gps(.lost), nil),
         ("off-route", .offRoute(crossTrackNM: 1.2), nil),
         ("chart-offline", .chartOffline, nil),
         ("tell-fis", .tellFIS(field: "LSGC"), nil),
         ("sigmet", .sigmet(summary: sigmetSummary(language: language)), nil),
         ("briefing", .briefing(.approach), nil)]
    }

    /// The undo messages the slot shows, at their longest: a 12-letter waypoint, a 12-hour clock, the
    /// longest check name.
    enum UndoKind: CaseIterable {
        case mark, automatic, legTimer, memory, freda
    }

    static func undoMessage(_ kind: UndoKind, language: String, waypoint: String = "SAIGNELÉGIER",
                            time: String = "10:58 PM") -> String {
        func text(_ key: String, _ english: String) -> String {
            localizedString(key: key, language: language, defaultValue: english)
        }
        switch kind {
        case .mark: return String(format: text("nav.markedAt", "%1$@ passed at %2$@"), waypoint, time)
        case .automatic:
            return String(format: text("nav.markedAutomaticallyAt", "%1$@ marked automatically at %2$@"), waypoint, time)
        case .legTimer: return text("nav.legTimerReset", "Leg timer reset")
        case .memory:
            let check = text("phase.short.beforeEngineStart", "CHECK BEFORE ENGINE START")
            return String(format: text("cockpit.doneFromMemoryToast", "%@ done from memory"), check)
        case .freda: return String(format: text("freda.doneToast", "FREDA done at %@"), time)
        }
    }

    static func undoOffer(_ kind: UndoKind, language: String) -> NavUndoOffer {
        NavUndoOffer(message: undoMessage(kind, language: language),
                     style: kind == .mark || kind == .legTimer ? .filled : .outlined) {}
    }

    /// "SEV TURB · on route", as the wiring will name the SIGMET on the path.
    static func sigmetSummary(language: String) -> String {
        "SEV TURB · " + localizedString(key: "nav.sigmet.onRoute", language: language, defaultValue: "on route")
    }

    /// A light chart, as the ICAO chart is: a grid, the route in magenta, the aircraft where it is.
    struct Backdrop: View {
        let model: MapChromeModel

        var body: some View {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.95, green: 0.93, blue: 0.85)))
                var grid = Path()
                for x in stride(from: CGFloat(0), through: size.width, by: 60) {
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), through: size.height, by: 60) {
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.black.opacity(0.08)), lineWidth: 1)
                var route = Path()
                route.move(to: CGPoint(x: size.width * 0.15, y: size.height))
                route.addLine(to: CGPoint(x: size.width * 0.62, y: 0))
                context.stroke(route, with: .color(Color(red: 0.89, green: 0.30, blue: 0.69)), lineWidth: 4)
                if let aircraft = model.aircraft,
                   let point = OwnshipEdgeArrow.project(aircraft, region: model.region, heading: model.heading, size: size) {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)), with: .color(.white))
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)), with: .color(.black), lineWidth: 2)
                }
            }
        }
    }
}

/// The chrome over a light chart, at a device's chart size.
private struct MapChromePreview: View {
    let chart: MapChromeSample.Chart
    var status: CockpitStatus? = nil
    var undo: NavUndoOffer? = nil
    var panned = false
    var language: String? = nil

    var body: some View {
        let model = MapChromeSample.model(status: status, undo: undo, panned: panned, stale: true)
        CockpitMapChrome(model: model, actions: MapChromeActions(), scale: chart.scale, language: language,
                         scaleShownOverride: true)
            .frame(width: chart.size.width, height: chart.size.height)
            .background(MapChromeSample.Backdrop(model: model))
            .environment(\.cockpitTheme, .day)
    }
}

#Preview("iPad portrait, off route") { MapChromePreview(chart: .iPadPortrait, status: .offRoute(crossTrackNM: 1.2)) }
#Preview("iPad portrait, UNDO, panned") {
    MapChromePreview(chart: .iPadPortrait, status: .undo,
                     undo: MapChromeSample.undoOffer(.automatic, language: "fr"), panned: true, language: "fr")
}
#Preview("iPad on its side, NO GPS") { MapChromePreview(chart: .iPadLandscape, status: .gps(.lost)) }
#Preview("Phone, TELL FIS, French") {
    MapChromePreview(chart: .phone, status: .tellFIS(field: "LSGC"), panned: true, language: "fr")
}
#Preview("Phone, UNDO") {
    MapChromePreview(chart: .phone, status: .undo, undo: MapChromeSample.undoOffer(.mark, language: "en"))
}
#endif
