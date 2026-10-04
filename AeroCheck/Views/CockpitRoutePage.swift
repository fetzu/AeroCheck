import SwiftUI
import CoreLocation
import UIKit
import os

// MARK: - ROUTE (6.2, the Cockpit's pages)
//
// The third page, the pilot's pick only: where the flight goes and who to talk to on the way.
//
//   DEST    the destination (or the field diverted to): distance, ETE, ETA and Δ, the route to scale
//   LEGS | RADIO   every leg, and every frequency in the order of use, in one scroll: side by side
//                  on the iPad (`LegsPanelColumns`, 700 pt and wider), one above the other on a phone
//   Emergency      121.500, pinned under the scroll, whole, lined up with RADIO
//
// A leg's row opens MAP framed on that leg, with "Back to aircraft" and the leg's DIRECT (a waypoint
// ahead) or RESUME LEG (one passed, with its confirmation): the plan's Q7. The act band under the page
// has MAP's roles. Until 6.2 all of this was the map's legs panel, opened from its frequency card over
// the chart's foot; Plan › Map keeps that panel.

/// The Cockpit's ROUTE page. Its parts are views of their own: the DEST line follows every fix, the legs
/// the leg timer's second, the radio `CockpitRadio`.
struct CockpitRoutePage: View {
    let layout: CockpitLayout
    /// A leg's row: MAP framed on the leg arriving at that waypoint.
    let onShowLeg: (Int) -> Void
    /// The device's measures; the tests lay the phone's out on an iPad.
    var scale: CockpitScale = .current
    /// For the tests: each part of the page as laid out, in the page's space.
    var onLayout: ((RoutePagePart, CGRect) -> Void)? = nil

    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @Environment(\.cockpitTheme) private var theme

    static let space = "routePage"

    var body: some View {
        let hasLegs = flightPlanManager.activeFlightPlan != nil
        VStack(spacing: 0) {
            SeparateView { RouteDestinationSection(layout: layout, scale: scale) }
            SeparateView { RouteLegsAndRadio(layout: layout, hasLegs: hasLegs, onShowLeg: onShowLeg) }
                .frame(maxHeight: .infinity, alignment: .top)
                .routePagePart(.scroll)
            SeparateView { RouteEmergencyFoot(layout: layout, hasLegs: hasLegs) }
        }
        .background(theme.background)
        // MARK's UNDO (and a waypoint the flight marked, a check just confirmed), over the page's foot
        // and above the act band, as on CHECKLIST: the status slot is MAP's. (6.2, author's call)
        .overlay(alignment: .bottom) { AutoMarkUndoToast(narrow: layout != .wide) }
        .coordinateSpace(name: Self.space)
        .environment(\.routePageReporter, onLayout)
    }
}

/// A part of ROUTE, for the layout tests.
enum RoutePagePart: Hashable {
    case scroll, legs, radio, emergency
}

private struct RoutePageReporterKey: EnvironmentKey {
    static let defaultValue: ((RoutePagePart, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    /// ROUTE's layout hook, the tests' only.
    var routePageReporter: ((RoutePagePart, CGRect) -> Void)? {
        get { self[RoutePageReporterKey.self] }
        set { self[RoutePageReporterKey.self] = newValue }
    }
}

/// Reports a part's frame in the page's space, when a test asks: nothing at all otherwise.
private struct RoutePagePartReader: ViewModifier {
    let part: RoutePagePart
    @Environment(\.routePageReporter) private var report

    func body(content: Content) -> some View {
        if let report {
            content.background(GeometryReader { proxy in
                let _ = report(part, proxy.frame(in: .named(CockpitRoutePage.space)))
                Color.clear
            })
        } else {
            content
        }
    }
}

private extension View {
    func routePagePart(_ part: RoutePagePart) -> some View {
        modifier(RoutePagePartReader(part: part))
    }
}

// MARK: - DEST

/// The DEST line at the top of ROUTE, and, diverting with an ATC flight plan filed, the one thing to say
/// on the radio under it (it was on the map's next-waypoint card). Follows every fix.
struct RouteDestinationSection: View {
    let layout: CockpitLayout
    var scale: CockpitScale = .current

    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var threadManager: FlightThreadManager
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        if let plan = flightPlanManager.activeFlightPlan,
           let estimate = DestinationEstimator.estimate(DestinationInput(
               plan: plan, location: locationManager.currentLocation,
               groundSpeedKnots: locationManager.currentSpeedKnots)) {
            OfferedWidth {
                VStack(alignment: .leading, spacing: 8) {
                    DestinationLine(estimate: estimate, scale: scale,
                                    onResumeRoute: { flightPlanManager.resumeRoute() })
                    if estimate.kind == .diversion, threadManager.thread(forPlanId: plan.id)?.hasOpenFlightPlan == true {
                        Text(L10n.Trip.tellFIS(estimate.ident))
                            .font(.aero(size: CockpitType.label))
                            .foregroundColor(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, layout == .wide ? 16 : 12)
                .padding(.top, 12)
            }
        }
    }
}

/// Its content at the width it is offered, never wider: a line whose figures need more (the iPad's
/// one-line DEST in a narrow window) runs past its edge rather than widen the page, which then sat off
/// centre with every column moved. (6.2)
struct OfferedWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else { return child.sizeThatFits(proposal) }
        return CGSize(width: width, height: child.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - LEGS | RADIO

/// The legs and every frequency, in the page's one scroll: side by side where the legs keep their times
/// beside the frequencies (`LegsPanelColumns`), one above the other on a phone, the frequencies alone and
/// the page's width with no route. It opens on the leg being flown.
struct RouteLegsAndRadio: View {
    let layout: CockpitLayout
    let hasLegs: Bool
    let onShowLeg: (Int) -> Void

    /// How far the undo toast reaches over the scroll above Emergency: its height (two lines of message,
    /// the phone's compact one) and its 8 pt over the page's foot, less Emergency's row. Held by
    /// `CockpitRoutePageTests`. (6.2)
    static func toastClearance(_ layout: CockpitLayout) -> CGFloat {
        layout == .wide ? 52 : 24
    }

    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                Group {
                    if hasLegs {
                        LegsPanelColumns {
                            RouteLegsColumn(onShowLeg: onShowLeg)
                                .routePagePart(.legs)
                            RouteRadioColumn()
                                .routePagePart(.radio)
                        }
                    } else {
                        RouteRadioColumn()
                            .routePagePart(.radio)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Room at the foot for the undo toast, which lies over Emergency and a little of the scroll
            // for six seconds: the leg being flown, brought into view, is never under it. (6.2)
            .contentMargins(.bottom, Self.toastClearance(layout), for: .scrollContent)
            .modifier(SharpScrollEdges())
            .onAppear {
                // On the next turn, once the rows are laid out: only as far as it takes, not at all when
                // the leg is in view.
                guard let plan = flightPlanManager.activeFlightPlan,
                      let row = LegsPanelReveal.row(currentWaypointIndex: plan.currentWaypointIndex,
                                                    waypointCount: plan.waypoints.count) else { return }
                DispatchQueue.main.async { reader.scrollTo(LegsPanelReveal.RowID(index: row), anchor: nil) }
            }
        }
    }
}

/// No soft scroll edge effect (iOS 26) on a scroll read in flight: the leg being flown and NOW / NEXT
/// are never blurred or dimmed. Nothing lies over these scrolls today, and an upright window shows no
/// effect, scrolled or not; but under the iPad's landscape capture hook (`AEROCHECK_ORIENTATION`) the
/// top of ROUTE's scroll was blurred at rest, and a bar over the page (the read band to come) would do
/// it for real. ROUTE's scroll and Plan › Map's legs panel. (6.2)
struct SharpScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

/// The column headings: LEGS, RADIO.
private struct RouteColumnHeader: View {
    let title: String
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        Text(title)
            .font(.aero(size: CockpitType.label, weight: .semibold))
            .foregroundColor(theme.textSecondary)
            .lineLimit(1)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Every leg, planned, flown, being flown or ahead; a tap opens MAP on it. The leg timer's second redraws
/// the leg being flown.
struct RouteLegsColumn: View {
    let onShowLeg: (Int) -> Void

    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    var body: some View {
        if let plan = flightPlanManager.activeFlightPlan {
            VStack(alignment: .leading, spacing: 0) {
                RouteColumnHeader(title: L10n.Route.legs)
                ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, _ in
                    RouteLegRow(plan: plan, index: index,
                           actual: RouteLegRow.actualTime(plan: plan, index: index,
                                                     legTimer: flightPlanManager.chronometerElapsed)) {
                        onShowLeg(index)
                    }
                    .id(LegsPanelReveal.RowID(index: index))
                    if index < plan.waypoints.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Every frequency in the order of use (`CockpitRadio`): NOW and NEXT first, tagged. No "All
/// frequencies": the page has the room (the plan's Q6). Emergency is under the scroll.
struct RouteRadioColumn: View {
    @Environment(CockpitRadio.self) private var radio

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RouteColumnHeader(title: L10n.Route.radio)
            ForEach(radio.stations) { FrequencyRow(item: $0, large: true) }
        }
        // The column's width, whatever it lists: Emergency under it is as wide.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Emergency, under the scroll and outside it, always whole, lined up with RADIO above it: its column
/// beside the legs, the page's width under them or with no route (`LegsPanelColumns.frequencyFoot`).
struct RouteEmergencyFoot: View {
    let layout: CockpitLayout
    let hasLegs: Bool

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        LegsPanelColumns(content: .frequencyFoot(hasLegs: hasLegs)) {
            VStack(spacing: 0) {
                Rectangle().fill(theme.panelStroke).frame(height: 1)
                FrequencyRow(item: .emergency, large: true)
            }
            .routePagePart(.emergency)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

extension PhaseFrequency {
    /// 121.500, as the lists end.
    static let emergency = PhaseFrequency(station: SwissCommonFrequency.emergency.name,
                                          freq: SwissCommonFrequency.emergency.frequency,
                                          highlighted: false, isEmergency: true, role: .emergency)
}

// MARK: - A leg's row

/// One leg, the one ARRIVING at its waypoint: its number, its state, the waypoint, then PLAN (the planned
/// EET), ACT (the leg timer on the leg being flown, ATO to ATO on one flown) and Δ, in fixed columns
/// (`LegRowMetrics`). ROUTE's, Plan › Map's panel's and the Companion's; each says what a tap does.
/// (6.2: out of the map)
///
/// The figures go under the name wherever the route's longest name wouldn't be whole beside them
/// (`LegRowLayout`): on a phone the three columns left a name about 30 pt, "LS…" on a 17e, and
/// SAIGNELÉGIER fits beside them on no phone. Whole at the phone's 17 pt; on the iPad a name may still
/// shrink to 80 %, as it always could.
struct RouteLegRow: View {
    let plan: FlightPlan
    let index: Int
    /// The old sheet's narrow table, without heading and distance.
    var compact = false
    /// The kneeboard sizes (v6.0 · P6): the Cockpit's and the panel's.
    var large = true
    /// Plan › Map: the waypoint previewed on the map.
    var isPreview = false
    /// The time flown on the leg (`actualTime`).
    let actual: TimeInterval?
    /// The device's measures; the tests lay the phone's out on an iPad.
    var scale: CockpitScale = .current
    let onTap: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let waypoint = plan.waypoints[index]
        let isCurrent = index == plan.currentWaypointIndex
        let isPast = index < plan.currentWaypointIndex
        let leg = plan.legArriving(at: index)
        // Column widths follow the type (`LegRowMetrics`).
        let indexWidth: CGFloat = large ? LegRowMetrics.indexWidth : 16
        let timeWidth: CGFloat = large ? LegRowMetrics.timeWidth : 44
        let deltaWidth: CGFloat = large ? LegRowMetrics.deltaWidth : 52
        let nameScale = Self.nameMinimumScale(large: large, scale: scale)
        Button(action: onTap) {
            LegRowLayout(nameRoom: Self.nameRoom(plan: plan, size: large ? CockpitType.label(for: scale) : 13,
                                                  minimumScale: nameScale)) {
                // Sequence number: the numbered disc on the map. (v4 UI/UX Revamp)
                Text("\(index + 1)")
                    .font(.aero(size: large ? CockpitType.label(for: scale) : 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isCurrent ? theme.route : theme.textSecondary)
                    .frame(width: indexWidth, alignment: .center)
                Image(systemName: isPast ? "circle.fill" : (isCurrent ? "location.fill" : "circle"))
                    .font(.aero(size: large ? 14 : 9))
                    .foregroundColor(isPast ? theme.onTarget : (isCurrent ? theme.route : theme.textDim))
                Text(waypoint.name.isEmpty ? "WPT \(index + 1)" : waypoint.name)
                    // The label size, like the times beside it: at 24 pt a name had to shrink to fit the
                    // landscape column. The current leg reads by its colour.
                    .font(.aero(size: large ? CockpitType.label(for: scale) : 13, weight: isCurrent ? .bold : .regular, design: .monospaced))
                    .foregroundColor(isCurrent ? theme.route : theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(nameScale)
                    .modifier(LegRowPartReader(index: index, part: .name))
                // Fixed-width columns so every row's heading / distance / PLAN / ACT / Δ line up,
                // whether or not a leg has been flown yet. (v4 UI/UX Revamp)
                HStack(spacing: LegRowMetrics.timeSpacing) {
                    // Heading and distance on the old sheet only. (v4 UI/UX Revamp)
                    if !compact && !large {
                        Text(leg?.formattedMagneticCourse ?? "")
                            .foregroundColor(theme.textSecondary).frame(width: 38, alignment: .trailing)
                        Text(leg?.distance.map { String(format: "%.1f", $0) } ?? "")
                            .foregroundColor(theme.textSecondary).frame(width: 40, alignment: .trailing)
                    }
                    Text((leg?.totalLegEET).map(ActLegTimer.clock) ?? "")   // PLAN (EET)
                        .foregroundColor(large ? theme.textSecondary : theme.textDim)
                        .frame(width: timeWidth, alignment: .trailing)
                    Text(actual.map(ActLegTimer.clock) ?? "")              // ACT / live
                        .foregroundColor(isCurrent ? theme.route : theme.onTarget)
                        .frame(width: timeWidth, alignment: .trailing)
                    delta(planned: leg?.totalLegEET, actual: actual)       // Δ ahead/over
                        .frame(width: deltaWidth, alignment: .trailing)
                }
                .font(.aero(size: large ? CockpitType.label(for: scale) : 10, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(large ? 0.8 : 1)   // a little smaller rather than a time cut short
                .modifier(LegRowPartReader(index: index, part: .figures))
            }
            .padding(.horizontal, LegRowMetrics.horizontalPadding).padding(.vertical, large ? 9 : 7)
            .background(isPreview ? theme.info.opacity(0.14)
                        : (isCurrent ? theme.route.opacity(0.10) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Its place and whether it has a time over, for a UI test: "legRow.1.passed.ato".
        .accessibilityIdentifier("legRow.\(index).\(isPast ? "passed" : isCurrent ? "next" : "ahead")\(waypoint.actualTimeOver == nil ? "" : ".ato")")
    }

    /// ▲ ahead or ▼ over: the planned leg time less the time flown; blank until both exist.
    @ViewBuilder
    private func delta(planned: TimeInterval?, actual: TimeInterval?) -> some View {
        if let planned, let actual {
            let difference = planned - actual
            Text((difference >= 0 ? "▲" : "▼") + ActLegTimer.clock(abs(difference)))
                .foregroundColor(difference >= 0 ? theme.onTarget : theme.warning)
        } else {
            Text("")
        }
    }

    /// The space the layout tests read a row's parts in.
    static let space = "legRows"

    /// How far a name may shrink: not at all on a phone, where the label size is the in-flight minimum
    /// (17 pt); to 80 % on the iPad, as before.
    static func nameMinimumScale(large: Bool, scale: CockpitScale) -> CGFloat {
        large && scale == .kneeboard ? 0.8 : 1
    }

    /// The room the route's longest name needs at `size`, shrunk at most to `minimumScale`: every row of
    /// the route takes the same shape from it. B612 Mono, as the rows set it (the name of the leg being
    /// flown is bold, the same width).
    static func nameRoom(plan: FlightPlan, size: CGFloat, minimumScale: CGFloat) -> CGFloat {
        let names = plan.waypoints.enumerated().map { $1.name.isEmpty ? "WPT \($0 + 1)" : $1.name }
        let key = NameRoomKey(names: names, size: size, minimumScale: minimumScale)
        if let room = nameRooms.withLock({ $0[key] }) { return room }
        let font = UIFont.aero(size: size, weight: .bold, monospaced: true)
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // A point over, as SwiftUI rounds what it sets.
        let room = (widest * minimumScale).rounded(.up) + 1
        nameRooms.withLock { rooms in
            if rooms.count > 32 { rooms.removeAll() }
            rooms[key] = room
        }
        return room
    }

    private struct NameRoomKey: Hashable {
        let names: [String]
        let size: CGFloat
        let minimumScale: CGFloat
    }

    /// Every row asks on every second the leg timer ticks: measured once a route.
    private static let nameRooms = OSAllocatedUnfairLock<[NameRoomKey: CGFloat]>(initialState: [:])

    /// The time flown on the leg arriving at `index`: the leg timer on the leg being flown, ATO to ATO on
    /// one flown, nothing on a leg ahead. (v4 UI/UX Revamp)
    static func actualTime(plan: FlightPlan, index: Int, legTimer: TimeInterval) -> TimeInterval? {
        if index == plan.currentWaypointIndex {
            return legTimer > 0.5 ? legTimer : nil
        }
        if index < plan.currentWaypointIndex, index >= 1, plan.waypoints.indices.contains(index),
           let ato = plan.waypoints[index].actualTimeOver,
           let previous = plan.waypoints[index - 1].actualTimeOver {
            return ato.timeIntervalSince(previous)
        }
        return nil
    }
}

/// A part of a leg's row, for the layout tests.
enum LegRowPart: Hashable {
    case name, figures
}

private struct LegRowReporterKey: EnvironmentKey {
    static let defaultValue: ((Int, LegRowPart, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    /// The leg rows' layout hook, the tests' only: a row's index, the part, its frame in the space named
    /// `RouteLegRow.space`.
    var legRowReporter: ((Int, LegRowPart, CGRect) -> Void)? {
        get { self[LegRowReporterKey.self] }
        set { self[LegRowReporterKey.self] = newValue }
    }
}

/// Reports a part of a leg's row, when a test asks: nothing at all otherwise.
private struct LegRowPartReader: ViewModifier {
    let index: Int
    let part: LegRowPart
    @Environment(\.legRowReporter) private var report

    func body(content: Content) -> some View {
        if let report {
            content.background(GeometryReader { proxy in
                let _ = report(index, part, proxy.frame(in: .named(RouteLegRow.space)))
                Color.clear
            })
        } else {
            content
        }
    }
}

/// A leg's row for the room it has, its four parts in order: the number, the dot, the name, the figures
/// (PLAN, ACT, Δ). On one line where the route's longest name (`nameRoom`) is whole beside the figures,
/// as `HStack` set it: the name after the dot, the figures at the right, a spacing, the least gap and a
/// spacing between them (`LegRowMetrics.fixedWidth`). Else the figures on a second line, in the same
/// columns at the right, and the name has the row's width after the dot. Decided by the width and the
/// route alone, so every row of a route takes the same shape and no value moves anything. (6.2)
struct LegRowLayout: Layout {
    /// What the route's longest name needs, at the least it may shrink to.
    let nameRoom: CGFloat
    var spacing: CGFloat = LegRowMetrics.spacing
    var nameGap: CGFloat = LegRowMetrics.nameGap
    /// Between the name's line and the figures', when there are two.
    var lineSpacing: CGFloat = 2

    /// Whether the figures go under the name: `width` the row's, less its padding.
    static func figuresUnderName(width: CGFloat, lead: CGFloat, figures: CGFloat, nameRoom: CGFloat,
                                 spacing: CGFloat = LegRowMetrics.spacing,
                                 nameGap: CGFloat = LegRowMetrics.nameGap) -> Bool {
        width - lead - (2 * spacing + nameGap) - figures < nameRoom
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(proposal: proposal, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(proposal: ProposedViewSize, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 4 else { return [] }
        let number = subviews[0].sizeThatFits(.unspecified), dot = subviews[1].sizeThatFits(.unspecified)
        let figures = subviews[3].sizeThatFits(.unspecified)
        let lead = number.width + spacing + dot.width + spacing
        let between = 2 * spacing + nameGap
        // Asked for its ideal: one line, the name whole.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? lead + subviews[2].sizeThatFits(.unspecified).width + between + figures.width
        let twoLines = Self.figuresUnderName(width: width, lead: lead, figures: figures.width, nameRoom: nameRoom,
                                             spacing: spacing, nameGap: nameGap)
        let nameWidth = max(0, twoLines ? width - lead : width - lead - between - figures.width)
        let name = subviews[2].sizeThatFits(ProposedViewSize(width: nameWidth, height: nil))
        let line = max(number.height, dot.height, name.height, twoLines ? 0 : figures.height)
        func centred(_ size: CGSize, x: CGFloat, width: CGFloat? = nil) -> CGRect {
            CGRect(x: x, y: (line - size.height) / 2, width: width ?? size.width, height: size.height)
        }
        let figuresFrame = twoLines
            ? CGRect(x: width - figures.width, y: line + lineSpacing, width: figures.width, height: figures.height)
            : centred(figures, x: width - figures.width)
        return [centred(number, x: 0), centred(dot, x: number.width + spacing),
                centred(name, x: lead, width: min(name.width, nameWidth)), figuresFrame]
    }
}

// MARK: - A leg on MAP

/// What MAP does with a leg tapped on ROUTE: which waypoints it frames, and the leg's one action. Pure.
/// (6.2, the plan's Q7)
enum LegFraming {
    /// The leg's action beside "Back to aircraft".
    enum Action: Equatable {
        /// A waypoint ahead (or any, diverting: where the route is rejoined): fly to it now.
        case direct
        /// A waypoint passed: back onto its leg, after today's confirmation.
        case resumeLeg
        /// The leg being flown: nothing to do but look.
        case none
    }

    /// The waypoints of the leg arriving at `index`: the one before it and its own. The departure's row
    /// (0) has no leg arriving: the first leg, departure and first waypoint. One alone on a one-waypoint
    /// plan; none past its end.
    static func waypoints(leg index: Int, count: Int) -> [Int] {
        guard index >= 0, index < count else { return [] }
        guard count >= 2 else { return [index] }
        return index == 0 ? [0, 1] : [index - 1, index]
    }

    /// Their coordinates, as MAP frames them.
    static func coordinates(of plan: FlightPlan, leg index: Int) -> [CLLocationCoordinate2D] {
        waypoints(leg: index, count: plan.waypoints.count)
            .map { plan.waypoints[$0].coordinate }
            .filter(CLLocationCoordinate2DIsValid)
    }

    /// DIRECT for a waypoint ahead, RESUME LEG for one passed (and every one, the route flown), nothing
    /// for the one flown to; diverting, DIRECT for that one too, as the panel offered it.
    static func action(leg index: Int, nextIndex: Int, diverting: Bool) -> Action {
        if index < nextIndex { return .resumeLeg }
        if index > nextIndex { return .direct }
        return diverting ? .direct : .none
    }

    /// The room MAP leaves around the leg: clear of the chrome over the chart's top and foot, but never
    /// more than 45 % of the chart at the top, and the top and the foot together never more than 80 %, so a
    /// short chart (an iPad on its side, a phone) still shows the leg on a fifth of it. The foot takes
    /// what the top leaves: on a phone, with nothing over the chart's top since the read band (6.2), the
    /// whole bar at its foot.
    static func edgePadding(chartSize: CGSize, topChrome: CGFloat, bottomChrome: CGFloat) -> UIEdgeInsets {
        edgePadding(chartSize: chartSize, chrome: UIEdgeInsets(top: topChrome, left: 0, bottom: bottomChrome, right: 0))
    }

    /// The same around the chrome on every side: the Cockpit chart's (PR 4) has a stack at the right edge
    /// in iPad portrait. A side takes 16 pt past its chrome, at least the old 40 (a tenth of a narrow
    /// chart), at most 40 % of the width.
    static func edgePadding(chartSize: CGSize, chrome: UIEdgeInsets) -> UIEdgeInsets {
        let side = min(40, chartSize.width * 0.1)
        func across(_ chrome: CGFloat) -> CGFloat {
            chrome > 0 ? min(max(side, chrome + 16), chartSize.width * 0.4) : side
        }
        let top = min(chrome.top + 16, chartSize.height * 0.45)
        let bottom = min(chrome.bottom + 16, max(0, chartSize.height * 0.8 - top))
        return UIEdgeInsets(top: top, left: across(chrome.left), bottom: bottom, right: across(chrome.right))
    }
}

/// MAP showing a leg tapped on ROUTE: "Back to aircraft", and the leg's DIRECT (filled) or RESUME LEG
/// (outlined). Over the chart, never in its layout: at its foot, where the thumb is; beside a phone's
/// column on its side, at its top, in its next line's place.
struct FramedLegBar: View {
    let waypointName: String
    let action: LegFraming.Action
    let onBack: () -> Void
    let onDirect: () -> Void
    let onResume: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let phone = CockpitScale.current == .phone
        HStack(spacing: phone ? 8 : 12) {
            Button(action: onBack) {
                label(icon: "location.fill", title: L10n.Route.backToAircraft, filled: false, fills: phone)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.backToAircraft")
            if !phone { Spacer(minLength: 8) }
            switch action {
            case .direct:
                Button(action: onDirect) {
                    label(icon: "arrow.right", title: L10n.Route.direct(waypointName), filled: true, fills: phone)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.directTo")
            case .resumeLeg:
                Button(action: onResume) {
                    label(icon: "arrow.uturn.backward", title: L10n.Nav.resumeLeg, filled: false, fills: phone)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.resumeLeg")
            case .none:
                EmptyView()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.panelStroke, lineWidth: 1))
    }

    private func label(icon: String, title: String, filled: Bool, fills: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.aero(size: CockpitType.label, weight: .semibold))
            Text(title)
                .font(.aero(size: CockpitType.label, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
        }
        .foregroundColor(filled ? theme.actionText : theme.action)
        .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 10))
        .frame(maxWidth: fills ? .infinity : nil, minHeight: CockpitTarget.control)
        .background(RoundedRectangle(cornerRadius: 14).fill(filled ? theme.action : theme.action.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(filled ? Color.clear : theme.action.opacity(0.5), lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}

// MARK: - The radio, on every page

/// Keeps `CockpitRadio` current whatever page shows: on the phase, the waypoint flown to, the diversion,
/// the airport and airspace data arriving, and the aircraft moving 0.01°. On the Cockpit's frame, so
/// NOW and NEXT follow the flight on CHECKLIST too, where the map's recompute never ran. Loads the
/// airport database as the map did on appearing (and downloads it once if it was never downloaded):
/// NOW and NEXT need it. (6.2, ROUTE)
struct CockpitRadioFollower: ViewModifier {
    let radio: CockpitRadio

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @EnvironmentObject private var companion: CompanionConnectivityManager

    /// What the lists are computed again for, besides a move.
    struct Key: Equatable {
        let phase: ChecklistPhase
        let planId: UUID?
        let waypointCount: Int
        let nextIndex: Int?
        let diversion: String?
        let airports: Bool
        let airspace: Bool
        let airspaceCount: Int
    }

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onChange(of: key) { _, _ in recompute() }
            .onChange(of: locationManager.currentLocation) { _, location in
                radio.noteMove(to: location?.coordinate, plan: flightPlanManager.activeFlightPlan, sources: sources)
            }
    }

    private var key: Key {
        let plan = flightPlanManager.activeFlightPlan
        return Key(phase: appState.currentPhase, planId: plan?.id, waypointCount: plan?.waypoints.count ?? 0,
                   nextIndex: plan?.currentWaypointIndex, diversion: plan?.diversion?.ident,
                   airports: airportDataService.isDataAvailable, airspace: openAIPDataService.isDataAvailable,
                   airspaceCount: openAIPDataService.airspaceCount)
    }

    private var sources: PhaseFrequencyPlanner.Sources {
        .live(airports: airportDataService, openAIP: openAIPDataService)
    }

    private func recompute() {
        radio.update(position: locationManager.currentLocation?.coordinate,
                     plan: flightPlanManager.activeFlightPlan, sources: sources)
    }

    private func start() {
        // The Companion iPhone's NOW and NEXT are these. (6.2.0)
        companion.cockpitRadio = radio
        recompute()
        let airports = airportDataService
        let openAIP = openAIPDataService
        Task {
            await airports.ensureLoaded()
            // `ensureLoaded` only reads a cache: NOW and NEXT need the database, fetched once when it
            // was never downloaded. (v4 UI/UX Revamp fix)
            if !airports.isDataAvailable && !airports.isDownloading {
                await airports.downloadData()
            }
            // The CTRs for NEXT.
            if openAIP.isDataAvailable { await openAIP.ensureLoaded() }
            recompute()
        }
    }
}
