import SwiftUI
import UIKit
import os

// MARK: - The act band (6.2, the Cockpit's pages)
//
// What the pilot presses, in four fixed slots at the foot of the Cockpit, under every page: the same
// four frames whatever they hold, so the thumb learns the places once (AC 25-11B §6.2.1, the author's
// call of 3 Oct 2026). The page and the flight give the roles (`ActBandRoles`), never the frames
// (`ActBandLayout`):
//
//   CHECKLIST  S1 ENGINE START / SHUTDOWN in their phases, FREDA in cruise, else the check slot
//              S2 CHECK with the item, then ✓ DONE, NEXT, READY FOR LINE UP or END FLIGHT
//              S3 DEFER (dimmed when nothing can be deferred)   S4 More
//   MAP, ROUTE S1 the check slot   S2 START LEG, then MARK <wpt> with the leg timer (Routes, no route)
//              S3 Divert (amber while diverting)                S4 More
//   MAP and ROUTE, from the approach to the runway, and from circuit height:
//              S1 the check slot   S2 GO AROUND   S3 TOUCH-AND-GO   S4 More, Divert inside it
//
// Until 6.2 each pane had a thumb bar of its own: the checklist's laid itself out again with the phase
// (CHECK at the right end, the phase's action, FREDA or the circuit buttons coming and going), the map's
// held the slot, MARK, Divert and More. The band is the frame's now, and what the map's bar owned (MARK's
// UNDO, the Divert sheet, the leg timer's actions, the routes) is `CockpitNavState`'s.

/// What one slot of the act band holds.
enum ActSlotRole: Equatable {
    /// The check slot (`CockpitCheckSlot`). On CHECKLIST its "open the list" brings the current item into
    /// view instead.
    case checkSlot
    case engineStart
    case engineShutdown
    /// FREDA, in cruise outside circuits (`FredaThumbButton`).
    case freda
    /// CHECK with the item; then ✓ DONE (a memory check), NEXT (READY FOR LINE UP out of the check before
    /// departure), END FLIGHT at the last one.
    case checklistPrimary
    /// START LEG, then MARK <wpt> with the leg timer; dimmed once the route is flown.
    case mark
    /// No route: the way to one.
    case routes
    case goAround
    case touchAndGo
    /// DEFER: shown dimmed and disabled when there is nothing to defer (the check done, a memory check).
    case deferItem(enabled: Bool)
    /// Divert: amber while diverting, disabled with no route or with the route flown.
    case divert(enabled: Bool, diverting: Bool)
    /// More. `withDivert`: Divert is in it, where S3 holds something else.
    case more(withDivert: Bool)
}

/// The four roles for the page and the flight. Pure, so every combination is tested without a view.
enum ActBandRoles {
    /// `routeFlown`: every waypoint passed. `landingShown`: the landing check shown from circuit height
    /// (the flight cues). `canDefer`: an item to put off (the check open, not a memory check).
    static func make(page: CockpitPane, phase: ChecklistPhase, hasRoute: Bool, routeFlown: Bool = false,
                     diverting: Bool = false, circuits: Bool = false, landingShown: Bool = false,
                     canDefer: Bool = true) -> [ActSlotRole] {
        let legToFly = hasRoute && !routeFlown
        switch page {
        case .checklist:
            return [checklistFirst(phase: phase, circuits: circuits), .checklistPrimary,
                    .deferItem(enabled: canDefer), .more(withDivert: legToFly)]
        case .map, .route:
            // ROUTE has MAP's roles: the legs to mark and divert from are on it. (6.2, ROUTE)
            // The destination is marked by the landing: from the approach on, the runway's buttons take
            // MARK's and Divert's places, and Divert goes into More. (6.1, mockup M3)
            if phase == .approach || phase == .landing || landingShown {
                return [.checkSlot, .goAround, .touchAndGo, .more(withDivert: legToFly)]
            }
            guard hasRoute else {
                return [.checkSlot, .routes, .divert(enabled: false, diverting: false), .more(withDivert: false)]
            }
            return [.checkSlot, .mark, .divert(enabled: legToFly, diverting: diverting), .more(withDivert: false)]
        }
    }

    /// The checklist's first slot: the phase's own action where it has one, FREDA in cruise, else the
    /// check slot (the plan's Q11).
    private static func checklistFirst(phase: ChecklistPhase, circuits: Bool) -> ActSlotRole {
        if phase.showsEngineStartButton { return .engineStart }
        if phase.showsEngineShutdownButton { return .engineShutdown }
        if phase == .cruise && !circuits { return .freda }
        return .checkSlot
    }
}

// MARK: - The four frames

/// The band's measures for a layout and a device: the room between the slots, their height, and the
/// width of the two narrow ones.
struct ActBandMetrics: Equatable {
    var spacing: CGFloat
    var height: CGFloat
    /// S3 and S4.
    var narrowWidth: CGFloat
    /// The phone on its side (until its own pass): S3 over S4, half height each, beside S1 and S2.
    var stacksNarrow: Bool
    /// Between S3 and S4 one above the other.
    var narrowSpacing: CGFloat = 8

    static func make(layout: CockpitLayout, scale: CockpitScale = .current) -> ActBandMetrics {
        ActBandMetrics(spacing: CockpitType.size(kneeboard: 12, phone: 6, scale: scale),
                       height: CockpitType.size(kneeboard: 104, phone: 92, scale: scale),
                       narrowWidth: narrowWidth(scale: scale),
                       stacksNarrow: layout == .columns)
    }

    /// The narrow slots' text, from their edges: what a word has, less this on each side.
    static func narrowPadding(_ scale: CockpitScale = .current) -> CGFloat {
        CockpitType.size(kneeboard: 12, phone: 3, scale: scale)
    }

    /// How wide S3 and S4 are: the widest word either can ever carry, in English and in French, at the
    /// in-flight label size (DEFER, Divert, More, TOUCH-AND-GO on two lines), with its padding. Kept
    /// between 120 and 150 pt on the iPad and 72 and 80 on the phone, where S1 and S2 need the rest (the
    /// check slot's "CRUISE CHECK" on one line over its tick, about 100 pt).
    /// Measured once a device: the frames never follow the words on screen.
    static func narrowWidth(scale: CockpitScale) -> CGFloat {
        if let cached = measured.withLock({ $0[scale] }) { return cached }
        let widest = narrowTemplates.map { textWidth($0, size: CockpitType.label(for: scale)) }.max() ?? 0
        let bounds: ClosedRange<CGFloat> = scale == .phone ? 72...80 : 120...150
        let width = min(max((widest + 2 * narrowPadding(scale)).rounded(.up), bounds.lowerBound), bounds.upperBound)
        measured.withLock { $0[scale] = width }
        return width
    }

    /// Every line the narrow slots can show, in both languages.
    static var narrowTemplates: [String] {
        ["en", "fr"].flatMap { language -> [String] in
            let touchAndGo = localizedString(key: "checklist.touchAndGo", language: language, defaultValue: "TOUCH-AND-GO")
            return ["cockpit.defer", "act.divert", "nav.more"].map { localizedString(key: $0, language: language) }
                + ActBandText.twoLines(touchAndGo).components(separatedBy: "\n")
        }
    }

    /// `text` set in B612 Bold at `size`, as the slots set it.
    static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: UIFont.aero(size: size, weight: .bold)]).width
    }

    private static let measured = OSAllocatedUnfairLock<[CockpitScale: CGFloat]>(initialState: [:])
}

/// The four slots, left to right: S1 and S2 share what S3 and S4 leave. From the row's width and the
/// device's measures alone, never from what the slots hold, so a role changing (CHECK becoming NEXT,
/// MARK giving way to GO AROUND) moves nothing.
struct ActBandLayout: Layout {
    var metrics: ActBandMetrics
    /// Each slot as laid out (its index, its frame in the band): for the tests.
    var onPlace: ((Int, CGRect) -> Void)? = nil

    static func frames(width: CGFloat, metrics m: ActBandMetrics) -> [CGRect] {
        let narrow = min(m.narrowWidth, max(0, width / 4))
        if m.stacksNarrow {
            let wide = max(0, (width - narrow - 2 * m.spacing) / 2)
            let half = max(0, (m.height - m.narrowSpacing) / 2)
            let x = 2 * (wide + m.spacing)
            return [CGRect(x: 0, y: 0, width: wide, height: m.height),
                    CGRect(x: wide + m.spacing, y: 0, width: wide, height: m.height),
                    CGRect(x: x, y: 0, width: narrow, height: half),
                    CGRect(x: x, y: half + m.narrowSpacing, width: narrow, height: half)]
        }
        let wide = max(0, (width - 2 * narrow - 3 * m.spacing) / 2)
        let x = 2 * (wide + m.spacing)
        return [CGRect(x: 0, y: 0, width: wide, height: m.height),
                CGRect(x: wide + m.spacing, y: 0, width: wide, height: m.height),
                CGRect(x: x, y: 0, width: narrow, height: m.height),
                CGRect(x: x + narrow + m.spacing, y: 0, width: narrow, height: m.height)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? 4 * metrics.narrowWidth + 3 * metrics.spacing
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(width: bounds.width, metrics: metrics)
        for (index, subview) in subviews.enumerated() where frames.indices.contains(index) {
            let frame = frames[index]
            let size = ProposedViewSize(frame.size)
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: size)
            if let onPlace {
                let placed = subview.dimensions(in: size)
                onPlace(index, CGRect(origin: frame.origin, size: CGSize(width: placed.width, height: placed.height)))
            }
        }
    }
}

/// Words set for a narrow slot.
enum ActBandText {
    /// `text` on two lines, broken at the hyphen or the space nearest its middle: "TOUCH-" over "AND-GO",
    /// "POSÉ-" over "DÉCOLLÉ", "GO" over "AROUND". A hyphen stays on the first line, a space goes. One
    /// line when there is nowhere to break.
    static func twoLines(_ text: String) -> String {
        let characters = Array(text)
        let middle = Double(characters.count) / 2
        let breaks = characters.indices.filter { characters[$0] == "-" || characters[$0] == " " }
        guard let at = breaks.min(by: { abs(Double($0) + 0.5 - middle) < abs(Double($1) + 0.5 - middle) }),
              at > 0, at < characters.count - 1 else { return text }
        let first = String(characters[...at]).trimmingCharacters(in: .whitespaces)
        let second = String(characters[(at + 1)...]).trimmingCharacters(in: .whitespaces)
        return "\(first)\n\(second)"
    }
}

// MARK: - What the band owns

/// What the map's thumb bar owned and the band does now, for every page: the last MARK or leg-timer
/// reset offered back, the Divert sheet, the routes, the request a tap in the band sends to a page (the
/// checklist's current item into view), and the leg ROUTE asked MAP to show. The Cockpit's, put in the
/// environment by `FlightView`; Plan › Map has none.
@MainActor
@Observable
final class CockpitNavState {
    /// The last MARK or leg-timer reset, offered back for a few seconds (`MapUndoToast`,
    /// `AutoMarkUndoToast`). (v6.0 · C2)
    var undoOffer: NavUndoOffer?
    /// The Divert sheet, and the field it opens on when reached from an airport callout. (v5.1)
    var showDivert = false
    var divertPreselect: String?
    /// The routes, as a cover (FlightPlanningView).
    var showRoutes = false
    /// Bumped by the check slot on CHECKLIST: the list brings the current item into view.
    var checklistScrollRequest = 0
    /// A leg tapped on ROUTE: MAP shows it framed (the waypoint before it and its own), with "Back to
    /// aircraft" and the leg's DIRECT or RESUME LEG, until the pilot goes back to the aircraft or leaves
    /// MAP. The index of the waypoint the leg arrives at; 0, the departure's row, is the first leg. (6.2,
    /// ROUTE, the plan's Q7)
    var framedLeg: Int?

    /// MARK: the waypoint flown to is passed now, the next leg's timer starts, and the mark is offered
    /// back.
    func markWaypoint(in manager: FlightPlanManager, animated: Bool = true) {
        guard let plan = manager.activeFlightPlan, plan.currentWaypointIndex < plan.waypoints.count else { return }
        let index = plan.currentWaypointIndex
        let timer = manager.legTimerSnapshot
        manager.markWaypoint()
        guard let timer else { return }
        let name = plan.waypoints[index].name.isEmpty ? "WPT \(index + 1)" : plan.waypoints[index].name
        offerUndo(L10n.Nav.markedAt(name, FlightClock.now.formatted(date: .omitted, time: .shortened)),
                  in: manager, animated: animated) {
            manager.undoMark(ofWaypointAt: index, timer: timer)
        }
    }

    /// The leg timer back to zero, offered back.
    func resetLegTimer(in manager: FlightPlanManager, animated: Bool = true) {
        guard let timer = manager.legTimerSnapshot else { return }
        manager.resetChronometer()
        offerUndo(L10n.Nav.legTimerReset, in: manager, animated: animated) { manager.restoreLegTimer(timer) }
    }

    /// A mis-tap in turbulence is taken back with one tap, for a few seconds. One undo at a time: this one
    /// is newer than a waypoint the flight marked on its own.
    func offerUndo(_ message: String, in manager: FlightPlanManager, animated: Bool = true,
                   undo: @escaping () -> Void) {
        manager.dismissAutoMarkNotice()
        withAnimation(animated ? .easeOut(duration: 0.2) : nil) {
            undoOffer = NavUndoOffer(message: message, undo: undo)
        }
    }

    func openDivert(_ ident: String?) {
        divertPreselect = ident
        showDivert = true
    }

    func scrollChecklistToCurrentItem() {
        checklistScrollRequest &+= 1
    }

    /// The leg arriving at `index`, for MAP to frame; the page switch is the caller's.
    func showLeg(_ index: Int) {
        framedLeg = index
    }

    /// Back to the aircraft: the leg no longer framed.
    func endLegFraming() {
        framedLeg = nil
    }
}

/// What the band's buttons do that only `FlightView` can: its checklist's actions, its alerts, its
/// pages. The values are what it alone knows (the pulses).
struct CockpitActions {
    var check: () -> Void = {}
    var next: () -> Void = {}
    var memoryDone: () -> Void = {}
    var endFlight: () -> Void = {}
    var engineStart: () -> Void = {}
    var engineStartUpdate: () -> Void = {}
    var engineShutdown: () -> Void = {}
    var engineShutdownUpdate: () -> Void = {}
    /// The CHECKLIST page, as a tap on the picker picks it.
    var showChecklist: () -> Void = {}
    /// The MAP page.
    var showMap: () -> Void = {}
    /// The ROUTE page: More's legs and frequencies. (6.2, ROUTE)
    var showRoute: () -> Void = {}
    /// The V-SPEEDS drawer: More's, on the phone, whose picker has no room left for its chip. (6.2, Q8)
    var showVSpeeds: () -> Void = {}
    /// The deferred list: More's, on MAP and ROUTE, whose picker row lost its chip. (6.2)
    var showDeferred: () -> Void = {}
    /// ENGINE START or SHUTDOWN pulses: the list is done, the action is still to press.
    var pulseAction = false
    /// NEXT pulses: the check done, its action recorded.
    var nextReady = false
}

// MARK: - The band

/// The four slots under the page, in the frame's place: across the iPad and the phone in portrait,
/// at the foot of the phone's column on its side. The Divert sheet and the routes hang here, so they stay
/// up whichever page shows.
struct CockpitActBand: View {
    let page: CockpitPane
    let layout: CockpitLayout
    let actions: CockpitActions
    /// The device's measures; the tests lay the phone's out on an iPad.
    var scale: CockpitScale = .current
    /// For the tests: each slot as laid out.
    var onPlace: ((Int, CGRect) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    var body: some View {
        let metrics = ActBandMetrics.make(layout: layout, scale: scale)
        let roles = self.roles
        ActBandLayout(metrics: metrics, onPlace: onPlace) {
            ActSlotView(role: roles[0], page: page, half: false, actions: actions)
            ActSlotView(role: roles[1], page: page, half: false, actions: actions)
            ActSlotView(role: roles[2], page: page, half: metrics.stacksNarrow, actions: actions)
            ActSlotView(role: roles[3], page: page, half: metrics.stacksNarrow, actions: actions)
        }
        .padding(.horizontal, layout == .wide ? 16 : 12)
        .padding(.top, layout == .columns ? 6 : layout == .wide ? 12 : 10)
        .padding(.bottom, layout == .columns ? 12 : layout == .wide ? 12 : 10)
        .background { if layout != .columns { theme.panel.ignoresSafeArea(edges: .bottom) } }
        .overlay(alignment: .top) {
            if layout != .columns { Rectangle().fill(theme.panelStroke).frame(height: 1) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: appState.getHighlightedItem(for: appState.currentPhase))
        .modifier(ActBandPresentations())
    }

    private var roles: [ActSlotRole] {
        let plan = flightPlanManager.activeFlightPlan
        return ActBandRoles.make(page: page, phase: appState.currentPhase, hasRoute: plan != nil,
                                 routeFlown: flightPlanManager.isFlightPlanCompleted,
                                 diverting: plan?.diversion != nil, circuits: appState.isCircuitMode,
                                 landingShown: appState.landingCheckShown,
                                 canDefer: !appState.currentCheckIsDone && !appState.currentCheckAwaitsConfirmation)
    }
}

/// The Divert sheet and the routes' cover, on the band rather than on `FlightView.body`, which is as long
/// as the compiler of the CodeQL job allows.
private struct ActBandPresentations: ViewModifier {
    @Environment(CockpitNavState.self) private var navState
    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var aircraftDataService: AircraftDataService
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @EnvironmentObject private var threadManager: FlightThreadManager

    func body(content: Content) -> some View {
        @Bindable var navState = navState
        content
            .sheet(isPresented: $navState.showDivert) { divertSheet }
            .fullScreenCover(isPresented: $navState.showRoutes) { routes }
    }

    private var divertSheet: some View {
        DivertSheet(onClose: { navState.showDivert = false }, preselectedIdent: navState.divertPreselect)
            .environment(\.cockpitTheme, theme)
            .environmentObject(flightPlanManager)
            .environmentObject(airportDataService)
            .environmentObject(locationManager)
            .presentationDetents([.large])
    }

    private var routes: some View {
        FlightPlanningView()
            .environment(appState)
            .environmentObject(flightPlanManager)
            .environmentObject(threadManager)
            .environmentObject(airportDataService)
            .environmentObject(aircraftDataService)
            .environmentObject(openAIPDataService)
            .environmentObject(locationManager)
    }
}

/// One slot: its role's button, filling the frame it is given. `half`: S3 or S4 on the phone on its
/// side, half the band's height.
struct ActSlotView: View {
    let role: ActSlotRole
    let page: CockpitPane
    let half: Bool
    let actions: CockpitActions

    @Environment(AppState.self) private var appState
    @Environment(CockpitNavState.self) private var navState
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch role {
        case .checkSlot:
            // On CHECKLIST the list is there already: "N items" brings the current one into view.
            CockpitCheckSlot(onShowChecklist: page == .checklist ? { navState.scrollChecklistToCurrentItem() }
                                                                 : actions.showChecklist)
        case .engineStart, .engineShutdown:
            ActPhaseActionButton(shutdown: role == .engineShutdown, actions: actions)
        case .freda:
            FredaThumbButton()
        case .checklistPrimary:
            ActChecklistPrimary(actions: actions)
        case .mark:
            ActMarkButton()
        case .routes:
            ActRoutesButton()
        case .goAround:
            // About 100 pt on the phone: "GO" over "AROUND".
            MapFlightEventButton(event: .goAround, narrow: CockpitScale.current == .phone,
                                 twoLines: CockpitScale.current == .phone)
        case .touchAndGo:
            MapFlightEventButton(event: .touchAndGo, narrow: true, twoLines: true, half: half)
        case .deferItem(let enabled):
            Button { appState.deferHighlightedItem() } label: {
                ActNarrowLabel(icon: "clock.arrow.circlepath", title: L10n.Cockpit.deferItem, tint: theme.warning,
                               half: half)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .accessibilityLabel(L10n.Cockpit.deferItem)
            .accessibilityHint(L10n.Cockpit.deferHint)
            .accessibilityIdentifier("cockpit.defer")
        case .divert(let enabled, let diverting):
            Button { navState.openDivert(nil) } label: {
                ActNarrowLabel(icon: "arrow.triangle.turn.up.right.diamond.fill", title: L10n.Act.divert,
                               tint: diverting ? theme.warning : theme.action, half: half)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .accessibilityLabel(L10n.Act.divert)
            .accessibilityIdentifier("act.divert")
        case .more(let withDivert):
            CockpitMoreMenu(page: page, withDivert: withDivert, half: half, actions: actions)
        }
    }
}

/// A narrow slot's face: the icon over the word (DEFER, Divert, More), at the in-flight label size.
/// `half`: the word alone, half height. Its button says the word to VoiceOver, not the icon's name.
struct ActNarrowLabel: View {
    let icon: String
    let title: String
    let tint: Color
    var half: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            if !half {
                Image(systemName: icon).font(.aero(size: CockpitType.response, weight: .semibold))
            }
            Text(title)
                .font(.aero(size: CockpitType.label, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, ActBandMetrics.narrowPadding())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(tint)
        .background(RoundedRectangle(cornerRadius: half ? 12 : 18).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: half ? 12 : 18).stroke(tint.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - The checklist's slots

/// CHECK while items are open; the next phase once they're all done (a different gesture, so finishing
/// a list is never an accident); END FLIGHT at the end. A memory check (every item hidden) is confirmed
/// and left in one tap: "✓ CLIMB CHECK DONE", "NEXT: CRUISE CHECK · from memory", with the undo toast,
/// which takes both back (6.1, author's decision). Where it can't go on (the phase's own action still
/// to press, the last check), it only confirms, and NEXT follows. Out of the check before departure,
/// NEXT reads READY FOR LINE UP (`CockpitNextLabel`, 6.2). Always the second slot since 6.2.
struct ActChecklistPrimary: View {
    let actions: CockpitActions

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let phone = CockpitScale.current == .phone
        let filled = CockpitThumbButton.Style.filled(fill: theme.action, text: theme.actionText)
        if appState.currentCheckAwaitsConfirmation {
            let next = appState.memoryConfirmationMovesTo
            CockpitThumbButton(title: L10n.Cockpit.memoryCheckDone(appState.currentPhase.shortTitle),
                               subtitle: next.map { L10n.Cockpit.fromMemoryThenNext($0.shortTitle) } ?? L10n.Cockpit.fromMemory,
                               icon: phone ? nil : "checkmark", style: filled, titleLines: 2,
                               horizontalPadding: phone ? 8 : 14, action: actions.memoryDone)
                .accessibilityIdentifier("cockpit.memoryDone")
        } else if !appState.currentCheckIsDone {
            // The item under CHECK, on two lines: on the phone the slot is about 100 pt wide.
            CockpitThumbButton(title: L10n.Cockpit.check, subtitle: currentItemChallenge,
                               icon: phone ? nil : "checkmark", style: filled, subtitleLines: 2,
                               horizontalPadding: phone ? 8 : 14, action: actions.check)
                .accessibilityIdentifier("cockpit.check")
        } else if appState.isLastPhase {
            CockpitThumbButton(title: L10n.Button.endFlight, icon: phone ? nil : "flag.checkered",
                               style: .filled(fill: theme.danger, text: .white), titleLines: 2,
                               horizontalPadding: phone ? 8 : 14, action: actions.endFlight)
                .accessibilityIdentifier("cockpit.endFlight")
        } else {
            let label = CockpitNextLabel(
                leaving: appState.currentPhase,
                to: appState.currentPhase.nextNavigable(circuitMode: appState.isCircuitMode),
                deferred: appState.currentPhaseDeferredIds.count)
            CockpitThumbButton(title: label.title, subtitle: label.subtitle, icon: phone ? nil : label.icon,
                               style: filled, titleLines: 2, horizontalPadding: phone ? 8 : 14, action: actions.next)
                .accessibilityIdentifier("cockpit.next")
                .accessibilityHint(label.accessibilityHint ?? "")
                .modifier(PulseModifier(isActive: actions.nextReady))
        }
    }

    /// The challenge of the highlighted item, shown on CHECK so the button says what it checks.
    private var currentItemChallenge: String? {
        let items = appState.activeChecklist.visibleItems(for: appState.currentPhase,
                                                          learningMode: appState.effectiveLearningMode)
        let index = appState.getHighlightedItem(for: appState.currentPhase)
        return items.indices.contains(index) ? items[index].challenge : nil
    }
}

/// ENGINE START or ENGINE SHUTDOWN, in their phases: the first slot, where the hand finds them before
/// CHECK. Recorded, they show their time and keep their place (held 1.5 s, they ask to update it).
struct ActPhaseActionButton: View {
    let shutdown: Bool
    let actions: CockpitActions

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let language = appState.settings.checklistLanguage.resolvedLanguage
        if shutdown {
            TimestampActionButton(
                title: L10n.ChecklistAction.engineShutdown(language: language),
                icon: "engine.combustion.fill", color: theme.danger,
                timestamp: appState.formattedEngineShutdownTime,
                timestampLabel: L10n.ChecklistAction.shutdown(language: language),
                isPulsing: actions.pulseAction, compact: true, minHeight: CockpitTarget.thumb,
                onFirstPress: actions.engineShutdown, onUpdateTime: actions.engineShutdownUpdate)
            .accessibilityIdentifier("cockpit.engineShutdown")
        } else {
            TimestampActionButton(
                title: L10n.ChecklistAction.engineStart(language: language),
                icon: "engine.combustion.fill", color: theme.onTarget,
                timestamp: appState.formattedEngineStartTime,
                timestampLabel: L10n.ChecklistAction.started(language: language),
                isPulsing: actions.pulseAction, compact: true, minHeight: CockpitTarget.thumb,
                onFirstPress: actions.engineStart, onUpdateTime: actions.engineStartUpdate)
            .accessibilityIdentifier("cockpit.engineStart")
        }
    }
}

// MARK: - The map's slots

/// START LEG before the timer runs, then MARK named after the waypoint, with the leg timer under it:
/// "LEG 2:05 / 17:32" on the iPad, "LSGC · 2:05" under MARK on the phone. The route flown, MARK keeps
/// its place, dimmed. The one-second clock is this view's alone. (6.1, mockup M2)
struct ActMarkButton: View {
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @Environment(CockpitNavState.self) private var navState
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let plan = flightPlanManager.activeFlightPlan, plan.currentWaypointIndex < plan.waypoints.count {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                button(plan, leg: ActLegTimer(plan: plan, manager: flightPlanManager))
            }
        } else {
            // The route flown: nothing left to mark, the slot kept.
            face(icon: "mappin.and.ellipse", title: L10n.Nav.mark, subtitle: nil)
                .opacity(0.4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.Nav.mark)
                .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder
    private func button(_ plan: FlightPlan, leg: ActLegTimer) -> some View {
        if !leg.started {
            primary(icon: "stopwatch", title: L10n.Nav.startLegTimer, subtitle: nil) {
                flightPlanManager.startChronometer()
            }
            .accessibilityIdentifier("map.startLeg")
        } else {
            let name = plan.waypoints[plan.currentWaypointIndex].name
            if CockpitScale.current == .phone {
                // The phone: the waypoint under MARK, where "MARK LSGC" on one line had to shrink.
                let parts = [name.isEmpty ? nil : name, leg.text(planned: false)].compactMap { $0 }
                primary(icon: "mappin.and.ellipse", title: L10n.Nav.mark, subtitle: parts.joined(separator: " · ")) {
                    navState.markWaypoint(in: flightPlanManager, animated: !reduceMotion)
                }
                .accessibilityIdentifier("map.mark")
            } else {
                primary(icon: "mappin.and.ellipse", title: name.isEmpty ? L10n.Nav.mark : "\(L10n.Nav.mark) \(name)",
                        subtitle: "\(L10n.Nav.leg) \(leg.text(planned: true))") {
                    navState.markWaypoint(in: flightPlanManager, animated: !reduceMotion)
                }
                .accessibilityIdentifier("map.mark")
            }
        }
    }

    private func primary(icon: String, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) { face(icon: icon, title: title, subtitle: subtitle) }
            .buttonStyle(.plain)
            .accessibilityLabel(subtitle.map { "\(title) \($0)" } ?? title)
    }

    /// The name on two lines where it runs long ("MARK" over "SAIGNELEGIER"), the leg's time on one.
    private func face(icon: String, title: String, subtitle: String?) -> some View {
        let phone = CockpitScale.current == .phone
        return VStack(spacing: 2) {
            HStack(spacing: CockpitType.size(kneeboard: 12, phone: 8)) {
                if !phone {
                    Image(systemName: icon).font(.aero(size: CockpitType.button, weight: .bold))
                }
                Text(title)
                    .font(.aero(size: CockpitType.button, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.aero(size: CockpitType.label, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .lineLimit(phone ? 2 : 1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundColor(theme.actionText)
        .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(theme.action))
        .contentShape(Rectangle())
    }
}

/// The leg timer as MARK reads it.
struct ActLegTimer {
    let planned: TimeInterval?
    let running: Bool
    let elapsed: TimeInterval
    var started: Bool { running || elapsed > 0.5 }

    @MainActor
    init(plan: FlightPlan, manager: FlightPlanManager) {
        planned = plan.legArriving(at: plan.currentWaypointIndex)?.totalLegEET
        running = manager.isChronometerRunning
        elapsed = manager.chronometerElapsed
    }

    init(planned: TimeInterval?, running: Bool, elapsed: TimeInterval) {
        self.planned = planned
        self.running = running
        self.elapsed = elapsed
    }

    /// The leg time so far, against the planned one where there's room ("2:05 / 17:32"); paused, it says so.
    func text(planned withPlanned: Bool) -> String {
        var text = Self.clock(elapsed)
        if withPlanned, let planned { text += " / \(Self.clock(planned))" }
        if !running { text += " ‖" }
        return text
    }

    /// A duration as "M:SS" (or "H:MM:SS" past an hour).
    static func clock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// No route on the map: the way to one, where MARK would be, as tall.
struct ActRoutesButton: View {
    @Environment(CockpitNavState.self) private var navState
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let phone = CockpitScale.current == .phone
        CockpitThumbButton(title: L10n.Ground.planRoutes,
                           icon: phone ? nil : "point.topleft.down.to.point.bottomright.curvepath",
                           style: .outlined(tint: theme.action), horizontalPadding: phone ? 8 : 14) {
            navState.showRoutes = true
        }
        .accessibilityIdentifier("act.routes")
    }
}

/// The rarer actions, on every page: Divert where its slot holds something else, the leg timer's pause
/// and reset (the reset offers undo), the legs and frequencies (ROUTE), what is deferred (on MAP and
/// ROUTE, whose picker row has no room for its chip since 6.2), V-SPEEDS on the phone, and the routes.
struct CockpitMoreMenu: View {
    let page: CockpitPane
    let withDivert: Bool
    var half: Bool = false
    let actions: CockpitActions

    @Environment(CockpitNavState.self) private var navState
    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    var body: some View {
        Menu {
            if withDivert {
                Button { navState.openDivert(nil) } label: {
                    Label(L10n.Act.divert, systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
            }
            legTimerItems
            if page != .route {
                Button(action: actions.showRoute) {
                    Label(L10n.Nav.legsAndFrequencies, systemImage: "list.bullet")
                }
            }
            // On CHECKLIST the deferred chip is at the top of the list.
            if page != .checklist && appState.hasDeferredWork {
                Button(action: actions.showDeferred) {
                    Label(L10n.Deferred.summary(checks: appState.deferredChecks.count, items: appState.deferredItemCount),
                          systemImage: "clock.arrow.circlepath")
                }
            }
            if CockpitScale.current == .phone {
                // V-SPEEDS stays English in French, as on its chip.
                Button(action: actions.showVSpeeds) {
                    Label { Text(verbatim: "V-SPEEDS") } icon: { Image(systemName: "speedometer") }
                }
            }
            Button { navState.showRoutes = true } label: {
                Label(L10n.Ground.planRoutes, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        } label: {
            ActNarrowLabel(icon: "ellipsis.circle", title: L10n.Nav.more, tint: theme.action, half: half)
        }
        .accessibilityLabel(L10n.Nav.more)
        .accessibilityIdentifier("act.more")
    }

    @ViewBuilder
    private var legTimerItems: some View {
        if flightPlanManager.activeFlightPlan != nil {
            let running = flightPlanManager.isChronometerRunning
            if running || flightPlanManager.chronometerElapsed > 0.5 {
                Button {
                    running ? flightPlanManager.pauseChronometer() : flightPlanManager.startChronometer()
                } label: {
                    Label(running ? L10n.Nav.pauseChronometer : L10n.Nav.startChronometer,
                          systemImage: running ? "pause.fill" : "play.fill")
                }
                Button(role: .destructive) {
                    navState.resetLegTimer(in: flightPlanManager, animated: !reduceMotion)
                } label: {
                    Label(L10n.Nav.resetChronometer, systemImage: "arrow.counterclockwise")
                }
            }
        }
    }
}
