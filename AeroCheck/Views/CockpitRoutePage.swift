import SwiftUI
import CoreLocation
import UIKit
import os

// MARK: - ROUTE (6.2, the Cockpit's pages)
//
// The third page, the pilot's pick only: where the flight goes and who to talk to on the way.
//
//   DEST    the destination (or the field diverted to): distance, ETE, ETA and Δ, the route to scale
//   LEGS | RADIO   every leg, and every frequency in the order of use, each in its own scroll: side by
//                  side on the iPad (`LegsPanelColumns`, 700 pt and wider); on a phone one at a time, each
//                  with the whole page, under a LEGS | RADIO switch (`RouteListSwitch`). LEGS follows the
//                  leg being flown.
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

/// A part of ROUTE, for the layout tests: the area under DEST, the columns' content, their scrolls,
/// Emergency.
enum RoutePagePart: Hashable {
    case scroll, legs, radio, legsScroll, radioScroll, emergency, listSwitch
}

/// Which list a phone's ROUTE shows (`RouteListSwitch`). (6.2.0)
enum RouteList: Hashable {
    case legs, radio
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
                // The phone's gaps even, as in the mockup the author picked: 8 pt between DEST, the switch
                // and the list. (6.2.0)
                .padding(.top, layout == .wide ? 12 : 8)
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

/// The legs and every frequency, each in a scroll of its own: side by side where the legs keep their times
/// beside the frequencies (`LegsPanelColumns`), one above the other on a phone (LEGS over at most half the
/// page), the frequencies alone and the page's width with no route. LEGS opens on the leg being flown and
/// follows it.
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
    /// The Cockpit's: which list the phone shows, which a tap on the read band's lines sets.
    @Environment(CockpitNavState.self) private var cockpitNav: CockpitNavState?
    /// Without the Cockpit's state (a preview): the list here.
    @State private var localList: RouteList = .legs

    private var list: Binding<RouteList> {
        Binding(get: { cockpitNav?.routeList ?? localList },
                set: { list in if let cockpitNav { cockpitNav.routeList = list } else { localList = list } })
    }

    var body: some View {
        // LEGS and RADIO each scroll on their own: in one scroll, a long route's legs took RADIO with them
        // off the page (6.2 device check, author's call: the same on the iPad and on a phone).
        GeometryReader { proxy in
            let width = max(0, proxy.size.width - 32)
            if !hasLegs {
                radioScroll()
                    .padding(.horizontal, 16)
            } else if LegsPanelColumns.isSideBySide(width: width) {
                let radioColumn = LegsPanelColumns.frequencyColumn(width: width, hasLegs: true)
                HStack(alignment: .top, spacing: LegsPanelColumns.columnSpacing) {
                    legsScroll()
                        .frame(width: radioColumn.minX - LegsPanelColumns.columnSpacing)
                    radioScroll()
                        .frame(width: radioColumn.width)
                }
                .padding(.horizontal, 16)
            } else {
                // A phone: one list at a time, each with the whole page, under LEGS | RADIO. LEGS over at
                // most half the page and RADIO under it left each about a leg and a half on an iPhone,
                // and three layouts were tried (the author's pick of three mockups, device check 11 Oct).
                VStack(alignment: .leading, spacing: 8) {
                    RouteListSwitch(selection: list)
                        .routePagePart(.listSwitch)
                    switch list.wrappedValue {
                    case .legs: legsScroll(showsHeader: false)
                    case .radio: radioScroll(showsHeader: false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    /// Every leg, the leg being flown brought into view as ROUTE opens and as each waypoint is passed (it
    /// stayed where it was after a MARK).
    private func legsScroll(showsHeader: Bool = true) -> some View {
        let legs = RouteLegsColumn(onShowLeg: onShowLeg, showsHeader: showsHeader).routePagePart(.legs)
        return ScrollViewReader { reader in
            scroll(legs)
            .routePagePart(.legsScroll)
            .onAppear {
                // On the next turn, once the rows are laid out: only as far as it takes, not at all when
                // the leg is in view.
                DispatchQueue.main.async { reveal(reader, animated: false) }
            }
            .onChange(of: flightPlanManager.activeFlightPlan?.currentWaypointIndex) { _, _ in
                reveal(reader, animated: true)
            }
        }
    }

    /// Every frequency, in its own scroll whatever LEGS does.
    private func radioScroll(showsHeader: Bool = true) -> some View {
        scroll(RouteRadioColumn(showsHeader: showsHeader).routePagePart(.radio))
            .routePagePart(.radioScroll)
    }

    /// One of the page's scrolls: the column, room at the foot for the undo toast, sharp edges.
    private func scroll<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, layout == .wide ? 12 : 4)
        }
        // Room at the foot for the undo toast, which lies over Emergency and a little of the scrolls for
        // six seconds: the leg being flown, brought into view, is never under it. (6.2)
        .contentMargins(.bottom, Self.toastClearance(layout), for: .scrollContent)
        .modifier(SharpScrollEdges())
    }

    /// The leg being flown into view, only as far as it takes.
    private func reveal(_ reader: ScrollViewProxy, animated: Bool) {
        guard let plan = flightPlanManager.activeFlightPlan,
              let row = LegsPanelReveal.row(currentWaypointIndex: plan.currentWaypointIndex,
                                            waypointCount: plan.waypoints.count) else { return }
        withAnimation(animated ? .easeInOut(duration: 0.25) : nil) {
            reader.scrollTo(LegsPanelReveal.RowID(index: row), anchor: nil)
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
    /// "LEGS" over the rows; not under the phone's switch, which says it.
    var showsHeader = true

    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    var body: some View {
        if let plan = flightPlanManager.activeFlightPlan {
            VStack(alignment: .leading, spacing: 0) {
                if showsHeader { RouteColumnHeader(title: L10n.Route.legs) }
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
/// frequencies": the page has the room (the plan's Q6). Emergency is under the scrolls.
struct RouteRadioColumn: View {
    /// "RADIO" over the rows; not under the phone's switch, which says it.
    var showsHeader = true

    @Environment(CockpitRadio.self) private var radio
    @Environment(CockpitNavState.self) private var cockpitNav: CockpitNavState?
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        // The CTRs around that the route doesn't enter come last, under their own heading: without it they read
        // as the route's next calls (the author's device check r3-6, 6.4.2).
        let firstNearby = radio.stations.first(where: \.nearby)?.id
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader { RouteColumnHeader(title: L10n.Route.radio) }
            ForEach(radio.stations) { item in
                if item.id == firstNearby {
                    RouteColumnHeader(title: L10n.Route.nearby)
                        .padding(.top, 12)
                        .accessibilityIdentifier("route.radio.nearby")
                }
                row(item)
            }
        }
        // The column's width, whatever it lists: Emergency under it is as wide.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row, outlined while it is NEXT and due; on the route's timeline a tap makes it NOW, offered back with
    /// UNDO: "contact Emmen Tower", off the route. (6.4.3, q7)
    @ViewBuilder
    private func row(_ item: PhaseFrequency) -> some View {
        let row = FrequencyRow(item: item, large: true)
            .overlay {
                if item.due {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(theme.info, lineWidth: 2)
                        .padding(.horizontal, -6)
                        .accessibilityHidden(true)
                }
            }
        if radio.onTimeline, CockpitRadio.picks(item) {
            Button {
                guard let taken = radio.select(item) else { return }
                cockpitNav?.offerUndo(taken.message, in: flightPlanManager, undo: taken.undo)
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.Read.switchHint())
        } else {
            row
        }
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
/// shrink to 80 %, as it always could. The departure's row has no figures (no leg arrives at it), so it
/// is always one line.
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
    /// ACT and Δ, the flight's times. Plan › Map shows PLAN alone, at the right: with no flight to time,
    /// the two empty columns left PLAN floating in the middle of the row (device check, 11 Oct). (6.2.0)
    var showsFlown = true
    /// Plan › Map on the iPad: under each leg's name its distance and a bar to the route's scale, the longest
    /// leg's the widest: how the waypoints split the route, where the route-to-scale bar under DEST showed
    /// nothing flown on the ground (the author's fix9-4, 11 Oct). The longest leg, NM; nil, no line (the
    /// Cockpit's ROUTE, the phones). (6.3.0)
    var longestLegNM: Double? = nil
    let onTap: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let waypoint = plan.waypoints[index]
        let isCurrent = index == plan.currentWaypointIndex
        let isPast = index < plan.currentWaypointIndex
        let leg = plan.legArriving(at: index)
        // Column widths follow the type (`LegRowMetrics`).
        let indexWidth: CGFloat = large ? LegRowMetrics.indexWidth(scale) : 16
        let timeWidth: CGFloat = large ? LegRowMetrics.timeWidth(scale) : 44
        let deltaWidth: CGFloat = large ? LegRowMetrics.deltaWidth(scale) : 52
        let nameScale = Self.nameMinimumScale(large: large, scale: scale)
        // No leg arrives at the departure: no figures there, ever.
        let hasFigures = index > 0
        let actual = hasFigures ? actual : nil
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                LegRowLayout(nameRoom: Self.nameRoom(plan: plan, size: large ? CockpitType.label(for: scale) : 13,
                                                      minimumScale: nameScale),
                             hasFigures: hasFigures, spacing: LegRowMetrics.spacing(scale),
                             nameGap: LegRowMetrics.nameGap(scale)) {
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
                    HStack(spacing: LegRowMetrics.timeSpacing(scale)) {
                        // Heading and distance on the old sheet only. (v4 UI/UX Revamp)
                        if !compact && !large {
                            Text(leg?.formattedMagneticCourse ?? "")
                                .foregroundColor(theme.textSecondary).frame(width: 38, alignment: .trailing)
                            Text(leg?.distance.map { String(format: "%.1f", $0) } ?? "")
                                .foregroundColor(theme.textSecondary).frame(width: 40, alignment: .trailing)
                        }
                        Text((leg?.totalLegEET).map(ActLegTimer.columnClock) ?? "")   // PLAN (EET)
                            .foregroundColor(large ? theme.textSecondary : theme.textDim)
                            .frame(width: timeWidth, alignment: .trailing)
                        if showsFlown {
                            Text(actual.map(ActLegTimer.columnClock) ?? "")          // ACT / live
                                .foregroundColor(isCurrent ? theme.route : theme.onTarget)
                                .frame(width: timeWidth, alignment: .trailing)
                            delta(planned: leg?.totalLegEET, actual: actual)   // Δ ahead/over
                                .frame(width: deltaWidth, alignment: .trailing)
                        }
                    }
                    .font(.aero(size: large ? CockpitType.label(for: scale) : 10, design: .monospaced))
                    .lineLimit(1)
                    // A little smaller rather than a time cut short, should a time ever outgrow its column (an
                    // hour is "1h05" since 6.3.0, which fits).
                    .minimumScaleFactor(large ? (scale == .phone ? 0.7 : 0.8) : 1)
                    .modifier(LegRowPartReader(index: index, part: .figures))
                }
                if let longestLegNM {
                    // Under the name, clear of the PLAN column; the departure keeps the line's room, empty, so every
                    // row has one height.
                    LegDistanceLine(share: hasFigures ? (leg?.distance).map { $0 / longestLegNM } : nil,
                                    distanceNM: hasFigures ? leg?.distance : nil, scale: scale)
                        .padding(.leading, indexWidth + LegRowMetrics.iconWidth + 2 * LegRowMetrics.spacing(scale))
                        .padding(.trailing, timeWidth + LegRowMetrics.spacing(scale))
                }
            }
            .modifier(LegRowPartReader(index: index, part: .row))
            .padding(.horizontal, LegRowMetrics.horizontalPadding(scale)).padding(.vertical, large ? 9 : 7)
            .background(isPreview ? theme.info.opacity(0.14)
                        : (isCurrent ? theme.route.opacity(0.10) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Its place and whether it has a time over, for a UI test: "legRow.1.passed.ato".
        .accessibilityIdentifier("legRow.\(index).\(isPast ? "passed" : isCurrent ? "next" : "ahead")\(waypoint.actualTimeOver == nil ? "" : ".ato")")
    }

    /// The longest leg of `plan`, NM: the scale of Plan › Map's distance bars. Nil without a leg's distance.
    static func longestLegNM(_ plan: FlightPlan) -> Double? {
        let distances = plan.waypoints.indices.compactMap { plan.legArriving(at: $0)?.distance }.filter { $0 > 0 }
        return distances.max()
    }

    /// ▲ ahead or ▼ over: the planned leg time less the time flown; blank until both exist.
    @ViewBuilder
    private func delta(planned: TimeInterval?, actual: TimeInterval?) -> some View {
        if let planned, let actual {
            let difference = planned - actual
            Text((difference >= 0 ? "▲" : "▼") + ActLegTimer.columnClock(abs(difference)))
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
        guard large else { return 1 }
        // The phone: one line a row, PLAN, ACT and Δ kept, the name smaller where it must be (about 14 pt for
        // SAIGNELÉGIER on an iPhone 17), never cut. Two lines a row left ROUTE's legs "all over the place"
        // (the author's choice of three, device check 11 Oct). (6.2.0)
        return scale == .kneeboard ? 0.8 : 0.5
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
        // The departure: the leg timer running before the take-off times no leg (MARK shows it).
        guard index > 0 else { return nil }
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
    case name, figures, row
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
    /// False on the departure's row, which has none: one line, the name the row's width.
    var hasFigures = true
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
        layOut(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = layOut(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// The parts' frames; `size` the row's.
    private func layOut(proposal: ProposedViewSize, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        guard subviews.count == 4 else { return ([], .zero) }
        let number = subviews[0].sizeThatFits(.unspecified), dot = subviews[1].sizeThatFits(.unspecified)
        let figures = subviews[3].sizeThatFits(.unspecified)
        let lead = number.width + spacing + dot.width + spacing
        let between = 2 * spacing + nameGap
        // Asked for its ideal: one line, the name whole.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? lead + subviews[2].sizeThatFits(.unspecified).width + between + figures.width
        let twoLines = hasFigures
            && Self.figuresUnderName(width: width, lead: lead, figures: figures.width, nameRoom: nameRoom,
                                     spacing: spacing, nameGap: nameGap)
        let nameWidth = max(0, twoLines || !hasFigures ? width - lead : width - lead - between - figures.width)
        let name = subviews[2].sizeThatFits(ProposedViewSize(width: nameWidth, height: nil))
        let line = max(number.height, dot.height, name.height, twoLines ? 0 : figures.height)
        func centred(_ size: CGSize, x: CGFloat, width: CGFloat? = nil) -> CGRect {
            CGRect(x: x, y: (line - size.height) / 2, width: width ?? size.width, height: size.height)
        }
        // The figures' line, under the name.
        let second = line + lineSpacing
        let figuresFrame = twoLines
            ? CGRect(x: width - figures.width, y: second, width: figures.width, height: figures.height)
            : centred(figures, x: width - figures.width)
        let frames = [centred(number, x: 0), centred(dot, x: number.width + spacing),
                      centred(name, x: lead, width: min(name.width, nameWidth)), figuresFrame]
        let height = twoLines ? second + figures.height : line
        return (frames, CGSize(width: width, height: height))
    }
}

/// LEGS | RADIO over a phone's ROUTE: which list has the page. A tap on the read band's next line opens
/// ROUTE on LEGS, on its NOW line on RADIO; the picker opens it on LEGS (`CockpitNavState.routeList`).
/// (6.2.0, device check 11 Oct)
struct RouteListSwitch: View {
    @Binding var selection: RouteList

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            segment(.legs, title: L10n.Route.legs)
            segment(.radio, title: L10n.Route.radio)
        }
    }

    private func segment(_ list: RouteList, title: String) -> some View {
        let selected = selection == list
        return Button { selection = list } label: {
            Text(title)
                .font(.aero(size: CockpitType.label, weight: .bold))
                .foregroundColor(selected ? theme.actionText : theme.action)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? theme.action : theme.action.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.action.opacity(selected ? 0 : 0.45), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("route.list.\(list == .legs ? "legs" : "radio")")
    }
}

/// Plan › Map's DIRECT to the waypoint previewed on the map (a later one, or any while diverting, where
/// the route is rejoined): one button the legs panel's width, under its scroll and over Emergency. It was
/// in the previewed row, a capsule over ACT and Δ taller than the row's line: that row grew, its figures
/// moved, and the rows no longer lined up, "messy" on the author's iPhone (device check, 11 Oct). (6.2.0)
struct LegsPanelDirectBar: View {
    let waypointName: String
    let onDirect: () -> Void

    @Environment(\.cockpitTheme) private var theme

    /// Whether the previewed waypoint at `index` offers DIRECT: one ahead of the waypoint flown to, or any
    /// while diverting. Pure.
    static func offers(index: Int, currentIndex: Int, diverting: Bool) -> Bool {
        index > currentIndex || diverting
    }

    /// The bar's height on the panel, its padding included: what the scroll gives up while it shows.
    static var height: CGFloat { CockpitTarget.control + 2 * verticalPadding }
    static let verticalPadding: CGFloat = 6

    var body: some View {
        Button(action: onDirect) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right").font(.aero(size: CockpitType.label, weight: .semibold))
                Text(L10n.Route.direct(waypointName))
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(theme.actionText)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: CockpitTarget.control, maxHeight: CockpitTarget.control)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.action))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("map.directTo")
        .padding(.vertical, Self.verticalPadding)
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
/// NOW and NEXT need it. (6.2, ROUTE) Keeps the radio's handover with the flight, and offers the app's own
/// switch back in the status slot. (6.4.3)
struct CockpitRadioFollower: ViewModifier {
    let radio: CockpitRadio

    @Environment(AppState.self) private var appState
    @Environment(CockpitNavState.self) private var cockpitNav
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @EnvironmentObject private var companion: CompanionConnectivityManager

    /// What the lists are computed again for, besides a move.
    struct Key: Equatable {
        let phase: ChecklistPhase
        let circuits: Bool
        let planId: UUID?
        let waypointCount: Int
        let nextIndex: Int?
        let diversion: String?
        let airports: Bool
        let airspace: Bool
        let airspaceCount: Int
        /// The route's points and typed frequencies: a route edited in flight keeps its id and count.
        let route: [String]
        /// The level-off came: the departure field gives way on the radio timeline. (6.4.2)
        let departureOver: Bool
        /// Aerodromes on the way in NEXT (Settings › Checklist & Flight). (6.4.2)
        let fieldsOnTheWay: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear { start() }
            .onChange(of: key) { _, _ in recompute() }
            // Another flight (a trip's next leg): its own handover, none yet. (6.4.3)
            .onChange(of: appState.currentFlight?.id) { _, _ in radio.resume(appState.radioHandover) }
            .onChange(of: locationManager.currentLocation) { _, location in
                radio.noteMove(to: location?.coordinate, plan: flightPlanManager.activeFlightPlan,
                               circuits: appState.isCircuitMode, situation: situation, sources: sources)
            }
            // The route's radio timeline, built again when the route or the data under it changes. (6.4.2)
            .task(id: timelineKey) { await buildTimeline() }
    }

    /// What the timeline is built from: the route, and whether the airport and airspace data are in.
    private var timelineKey: [String] {
        (CockpitRadio.timelineKey(flightPlanManager.activeFlightPlan) ?? [])
            + ["\(airportDataService.isDataAvailable)", "\(openAIPDataService.airspaceCount)"]
    }

    /// The radio timeline of the route flown, from the nav log's walk (`RouteRadioPlanner.plan`). (6.4.2)
    private func buildTimeline() async {
        guard let plan = flightPlanManager.activeFlightPlan, plan.waypoints.count >= 2 else {
            radio.setTimeline(nil, for: nil)
            recompute()
            return
        }
        let result = await RouteRadioPlanner.plan(for: plan, openAIP: openAIPDataService, airports: airportDataService)
        guard !Task.isCancelled else { return }
        radio.setTimeline(result.timeline, for: plan)
        recompute()
    }

    /// The flight beyond its position: its ground speed, whether its departure is over. (6.4.2)
    private var situation: PhaseFrequencyPlanner.Situation {
        let location = locationManager.currentLocation
        let speed = location.flatMap { $0.speed >= 0 ? $0.speed * 1.943_844 : nil }
        let altitude = location.flatMap { $0.verticalAccuracy > 0 ? $0.altitude * 3.280_84 : nil }
        return PhaseFrequencyPlanner.Situation(groundSpeedKt: speed, departureOver: departureOver,
                                               fieldsOnTheWay: appState.settings.showFieldsOnTheWay, altitudeFt: altitude)
    }

    /// The level-off, or a later cue (which brings it), on this leg.
    private var departureOver: Bool {
        let fired = appState.flightCues.fired
        return [.levelOff, .descent, .approach, .circuit].contains { fired[$0] != nil }
    }

    private var key: Key {
        let plan = flightPlanManager.activeFlightPlan
        return Key(phase: appState.currentPhase, circuits: appState.isCircuitMode, planId: plan?.id, waypointCount: plan?.waypoints.count ?? 0,
                   nextIndex: plan?.currentWaypointIndex, diversion: plan?.diversion?.ident,
                   airports: airportDataService.isDataAvailable, airspace: openAIPDataService.isDataAvailable,
                   airspaceCount: openAIPDataService.airspaceCount,
                   route: plan?.waypoints.map { "\($0.latitude),\($0.longitude),\($0.frequency ?? "")" } ?? [],
                   departureOver: departureOver, fieldsOnTheWay: appState.settings.showFieldsOnTheWay)
    }

    private var sources: PhaseFrequencyPlanner.Sources {
        .live(airports: airportDataService, openAIP: openAIPDataService)
    }

    private func recompute() {
        radio.update(position: locationManager.currentLocation?.coordinate,
                     plan: flightPlanManager.activeFlightPlan, circuits: appState.isCircuitMode,
                     situation: situation, sources: sources)
    }

    private func start() {
        // The Companion iPhone's NOW and NEXT are these. (6.2.0)
        companion.cockpitRadio = radio
        // The station the pilot is on, kept with the flight: a relaunch mid-flight takes it back. (6.4.3)
        radio.resume(appState.radioHandover)
        let appState = appState
        radio.onHandover = { handover in
            appState.radioHandover = handover
            appState.checkpointActiveFlight(force: true)
        }
        let cockpitNav = cockpitNav
        let manager = flightPlanManager
        radio.onSwitched = { message, undo in
            cockpitNav.offerUndo(message, in: manager, style: .outlined, undo: undo)
        }
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

/// A leg's distance and a bar to the route's scale (`share`: the leg over the longest leg), under its name on
/// Plan › Map's legs panel. Nil `share`: the line's room, empty (the departure). (6.3.0, fix9-4)
struct LegDistanceLine: View {
    let share: Double?
    let distanceNM: Double?
    let scale: CockpitScale

    @Environment(\.cockpitTheme) private var theme

    /// The figure's size: under the name's label size, a reading for the ground.
    static func figureSize(_ scale: CockpitScale) -> CGFloat { CockpitType.label(for: scale) - 4 }
    /// The bar's thickness.
    static let barHeight: CGFloat = 4

    var body: some View {
        let size = Self.figureSize(scale)
        GeometryReader { geometry in
            HStack(spacing: 6) {
                if let share, let distanceNM {
                    Capsule()
                        .fill(theme.info)
                        .frame(width: Self.barWidth(share: share, room: geometry.size.width - Self.figureRoom(size)),
                               height: Self.barHeight)
                        .accessibilityHidden(true)
                    Text(String(format: "%.0f NM", distanceNM))
                        .font(.aero(size: size, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: UIFont.aero(size: size, monospaced: true).lineHeight)
    }

    /// The figure's widest room, "000 NM", and the gap before it.
    static func figureRoom(_ size: CGFloat) -> CGFloat {
        ("000 NM" as NSString).size(withAttributes: [.font: UIFont.aero(size: size, monospaced: true)]).width + 6
    }

    /// The bar for `share` of the longest leg, in `room`: never under 4 pt, so a short leg still shows one.
    static func barWidth(share: Double, room: CGFloat) -> CGFloat {
        max(4, max(0, room) * CGFloat(min(max(share, 0), 1)))
    }
}
