import CoreLocation
import SwiftUI

// MARK: - The Companion iPhone in the Cockpit's frame (6.2.0)
//
// The phone's NAV screen is the phone Cockpit's ROUTE page, drawn from what the iPad streams:
//
//   read band  the strip, the next line and the NOW line, over both modes (CHECKLIST too)
//   page       DEST and the route to scale, the legs, the radio; Emergency pinned under them
//   act band   the iPad's check slot · START LEG, then MARK <wpt> · Divert · More (the leg timer, the nav
//              log), in the Cockpit's four frames (`ActBandLayout`)
//
// Everything here reads the iPad's stream and sends commands: the iPad stays the source of truth. Until
// 6.2.0 the screen was a hero card with the turn arrow, the plan, FREQ and the chronometer, RECORD ATO and
// the slot at its foot, and the strip at the bottom.

// MARK: - What the stream says

/// The NAV screen's figures from the iPad's stream: its plan, rebuilt from the snapshot, the aircraft's
/// position and ground speed. Read through the plan's own accessors (`legArriving(at:)`,
/// `navigationTarget`), so the phone's DEST line, legs and next line are the iPad's. Pure.
struct CompanionNav {
    /// The iPad's plan; nil without one.
    let plan: FlightPlan?
    /// Where the aircraft is, as the iPad streams it.
    let position: CLLocation?
    /// Knots, from the stream's ground speed.
    let groundSpeedKnots: Double
    /// Degrees true, the aircraft's track: what the turn arrow turns from.
    let track: Double?

    init(flightData: CompanionFlightData?, snapshot: CompanionFlightPlanSnapshot?) {
        plan = snapshot.map { FlightPlan(companion: $0, currentWaypointIndex: flightData?.currentWaypointIndex) }
        // With its altitude, as the iPad's own fix: `CLLocation.distance` counts an altitude whose
        // vertical accuracy is valid (above 0), 0.02 % farther at 5,000 ft.
        position = flightData.flatMap { data in
            guard let latitude = data.latitude, let longitude = data.longitude else { return nil }
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                              altitude: (data.altitudeFeet ?? 0) / Self.feetPerMetre, horizontalAccuracy: 0,
                              verticalAccuracy: data.altitudeFeet == nil ? -1 : 1, timestamp: data.timestamp)
        }
        groundSpeedKnots = (flightData?.speedMPS ?? 0) * Self.knotsPerMetrePerSecond
        track = flightData?.courseDegrees
    }

    /// The stream's units: the iPad sends metres per second and feet.
    static let knotsPerMetrePerSecond = 1.94384
    static let feetPerMetre = 3.28084

    /// The DEST line, now.
    func destination(now: Date) -> DestinationEstimate? {
        guard let plan else { return nil }
        return DestinationEstimator.estimate(input(plan: plan, now: now))
    }

    /// The plan adapter's input, without a distance to a target the phone can't place.
    func input(plan: FlightPlan, now: Date) -> DestinationInput {
        var input = DestinationInput(plan: plan, location: position, groundSpeedKnots: groundSpeedKnots, now: now)
        if !Self.isPlaceable(plan.navigationTarget) { input.liveDistanceNM = nil }
        return input
    }

    /// The leg being flown, for the next line: nil once the route is flown, or without one.
    var next: Next? {
        guard let plan, let target = plan.navigationTarget else { return nil }
        let placeable = Self.isPlaceable(target)
        let distance = placeable ? position.map {
            $0.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)) / 1852.0
        } : nil
        let bearing = placeable ? position?.coordinate.bearing(to: target.coordinate) : nil
        let name = target.name.isEmpty ? "WPT \(plan.currentWaypointIndex + 1)" : target.name
        return Next(ident: name, bearing: bearing, distanceNM: distance,
                    ete: NextLegLive.ete(distanceNM: distance, groundSpeedKnots: groundSpeedKnots),
                    turn: bearing.map { CompanionFlightView.signedAngle($0 - (track ?? 0)) },
                    diverting: target.isDiversion)
    }

    /// The next line's figures.
    struct Next: Equatable {
        let ident: String
        let bearing: Double?
        let distanceNM: Double?
        let ete: TimeInterval?
        /// Where the waypoint is from the aircraft's track, −180…180°: the turn arrow. Nil with no fix.
        let turn: Double?
        let diverting: Bool
    }

    /// A target the phone can measure to: the iPad's coordinates are kept as sent, so not always.
    private static func isPlaceable(_ target: NavigationTarget?) -> Bool {
        guard let target else { return false }
        return CompanionWireLimits.isValidCoordinate(latitude: target.latitude, longitude: target.longitude)
    }
}

extension NextFigures {
    /// The Companion's next line, the read band's (`ReadBandNextLine`): the leg the stream says is flown,
    /// measured as the iPad measures it (`CompanionNav.next`), its ETA from the streamed ground speed. The
    /// plain name, as on the phone Cockpit. (6.2.0)
    init(companion nav: CompanionNav, now: Date = FlightClock.now) {
        guard let next = nav.next else {
            self = .none
            return
        }
        self.init(ident: next.ident, diverting: next.diverting, bearing: next.bearing, distanceNM: next.distanceNM,
                  live: NextLegLive(distanceNM: next.distanceNM, groundSpeedKnots: nav.groundSpeedKnots, now: now))
    }
}

extension DestinationInput {
    /// The Companion's adapter: the iPad's plan snapshot and stream, read as the plan adapter reads the
    /// active plan, so the phone's DEST line is the iPad's. (6.2.0)
    init(snapshot: CompanionFlightPlanSnapshot, flightData: CompanionFlightData?, now: Date) {
        let nav = CompanionNav(flightData: flightData, snapshot: snapshot)
        self = nav.input(plan: nav.plan ?? FlightPlan(companion: snapshot), now: now)
    }
}

extension FlightPlan {
    /// The iPad's plan as its snapshot carries it: the waypoints with their legs and times, the waypoint
    /// flown to (the stream's, which is the fresher, when given) and the diversion. (6.2.0)
    init(companion snapshot: CompanionFlightPlanSnapshot, currentWaypointIndex: Int? = nil) {
        self.init(id: snapshot.planId, name: snapshot.planName,
                  waypoints: snapshot.waypoints.map(FlightPlanWaypoint.init(companion:)),
                  plannedDepartureTime: snapshot.plannedDepartureTime,
                  currentWaypointIndex: min(max(0, currentWaypointIndex ?? snapshot.currentWaypointIndex),
                                            snapshot.waypoints.count),
                  chronometerStartTime: snapshot.chronometerStartTime)
        // The iPad sends the field as a waypoint: its ident as the name, its name in the remarks.
        let leftRouteAt = self.currentWaypointIndex
        diversion = snapshot.diversion.map { field in
            Diversion(ident: field.name, name: field.remarks, latitude: field.latitude, longitude: field.longitude,
                      elevationFeet: field.altitude, frequency: field.frequency, leftRouteAt: leftRouteAt)
        }
    }
}

extension FlightPlanWaypoint {
    /// A waypoint of the iPad's plan, as its snapshot carries it.
    init(companion waypoint: CompanionWaypoint) {
        self.init(id: waypoint.id, name: waypoint.name,
                  coordinate: CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude),
                  altitude: waypoint.altitude, frequency: waypoint.frequency, remarks: waypoint.remarks,
                  magneticCourse: waypoint.magneticCourse, distance: waypoint.distance,
                  plannedGroundSpeed: waypoint.plannedGroundSpeed, estimatedElapsedTime: waypoint.estimatedElapsedTime,
                  legEETExtra: waypoint.legEETExtra, cumulativeEET: waypoint.cumulativeEET,
                  estimatedTimeOver: waypoint.estimatedTimeOver, actualTimeOver: waypoint.actualTimeOver)
    }
}

/// The NOW line: the iPad's NOW and NEXT, or, from an iPad that sends neither, the FREQ the phone always
/// showed. Pure.
enum CompanionNowLine: Equatable {
    case radio(now: CompanionFrequency?, next: CompanionFrequency?)
    /// The frequency typed for the waypoint flown to (or the field diverted to), named after it; else
    /// GUARD 121.50.
    case freq(station: String, frequency: String)

    static func make(flightData: CompanionFlightData?, plan: FlightPlan?) -> CompanionNowLine {
        if flightData?.nowFrequency != nil || flightData?.nextFrequency != nil {
            return .radio(now: flightData?.nowFrequency, next: flightData?.nextFrequency)
        }
        if let target = plan?.navigationTarget, let frequency = target.frequency, !frequency.isEmpty {
            return .freq(station: target.name.isEmpty ? "WPT" : target.name, frequency: frequency)
        }
        return .freq(station: "GUARD", frequency: "121.50")
    }
}

/// RADIO on the phone, from the stream: the iPad's NOW and NEXT, the field diverted to, then the
/// frequencies typed for the waypoints from the one flown to on, each once. Emergency is pinned under
/// the list, as on ROUTE. Pure.
enum CompanionRadio {
    static func stations(flightData: CompanionFlightData?, plan: FlightPlan?) -> [PhaseFrequency] {
        var items: [PhaseFrequency] = []
        var seen = Set<String>()
        func add(_ station: String, _ frequency: String, role: FreqRole = .other) {
            guard !frequency.isEmpty, seen.insert(frequency + "|" + station).inserted else { return }
            items.append(PhaseFrequency(station: station, freq: frequency, highlighted: role == .current,
                                        isEmergency: false, role: role))
        }
        if let now = flightData?.nowFrequency { add(now.station, now.frequency, role: .current) }
        if let next = flightData?.nextFrequency { add(next.station, next.frequency, role: .next) }
        if let plan {
            if let field = plan.diversion, let frequency = field.frequency { add(field.ident, frequency) }
            if plan.currentWaypointIndex < plan.waypoints.count {
                for waypoint in plan.waypoints[plan.currentWaypointIndex...] {
                    if let frequency = waypoint.frequency { add(waypoint.name.isEmpty ? "WPT" : waypoint.name, frequency) }
                }
            }
        }
        return items
    }
}

/// What the act band's second slot holds: START LEG before the leg timer runs, then MARK named after the
/// waypoint flown to, with the leg time; dimmed with no route, once it is flown, or on a waypoint already
/// timed. As the iPad's `ActMarkButton`. Pure.
enum CompanionMarkState: Equatable {
    case unavailable
    case startLeg
    case mark(waypointIndex: Int, name: String, legTime: String)

    static func make(plan: FlightPlan?, flightData: CompanionFlightData?) -> CompanionMarkState {
        guard let plan, plan.waypoints.indices.contains(plan.currentWaypointIndex) else { return .unavailable }
        let index = plan.currentWaypointIndex
        guard plan.waypoints[index].actualTimeOver == nil else { return .unavailable }
        let timer = ActLegTimer(planned: nil, running: flightData?.chronometerStartTime != nil,
                                elapsed: flightData?.chronometerElapsed ?? 0)
        guard timer.started else { return .startLeg }
        let name = plan.waypoints[index].name
        return .mark(waypointIndex: index, name: name.isEmpty ? "WPT \(index + 1)" : name,
                     legTime: timer.text(planned: false))
    }
}

// MARK: - The read band

/// The strip, the next line and the NOW line, over both modes; a tap on either line shows NAV, as on the
/// Cockpit it opens ROUTE. Every value sits in a cell as wide as its widest, so nothing moves when one
/// changes, appears or goes. Dimmed while the stream is late.
///
/// The next line is the phone Cockpit's (`ReadBandNextLine`, with the turn arrow). The NOW line stays the
/// Companion's own: it carries the iPad's NOW and NEXT side by side, or an older iPad's FREQ, where the
/// Cockpit's phone has NOW alone, from its own radio.
struct CompanionReadBand: View {
    let flightData: CompanionFlightData?
    let nav: CompanionNav
    let onShowNav: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            CompanionStrip(flightData: flightData)
            ReadBandNextLine(figures: NextFigures(companion: nav), turn: .some(nav.next?.turn), onTap: onShowNav)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.panelStroke, lineWidth: 1))
            CompanionNowLineView(line: CompanionNowLine.make(flightData: flightData, plan: nav.plan), onTap: onShowNav)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}

/// GS, ALT and TRK, as the phone's strip has always shown them, now at the top: each value in a
/// widest-value cell.
struct CompanionStrip: View {
    let flightData: CompanionFlightData?

    @Environment(\.cockpitTheme) private var theme

    /// Each cell as wide as its widest value, the room left shared out between them: equal thirds cut
    /// "ALT" in two beside a five-digit altitude.
    var body: some View {
        HStack(spacing: 0) {
            cell("GS", Self.speed(flightData), widest: "000", unit: "kt")
            Spacer(minLength: 4)
            divider
            Spacer(minLength: 4)
            cell("ALT", Self.altitude(flightData), widest: "00000", unit: "ft")
            Spacer(minLength: 4)
            divider
            Spacer(minLength: 4)
            cell("TRK", Self.track(flightData), widest: "000", unit: "°")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.panelStroke, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(theme.panelStroke).frame(width: 1, height: 24)
    }

    private func cell(_ label: String, _ value: String, widest: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: label)
                .font(.aero(size: CockpitType.label, weight: .medium, design: .monospaced))
                .foregroundColor(theme.textSecondary)
            DestinationFigureCell(text: value, widest: [widest, "---"],
                                  font: .aero(size: CockpitType.row, weight: .bold, design: .monospaced),
                                  color: theme.textPrimary)
            Text(verbatim: unit)
                .font(.aero(size: CockpitType.label, design: .monospaced))
                .foregroundColor(theme.textSecondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    static func speed(_ data: CompanionFlightData?) -> String {
        guard let s = data?.speedMPS else { return "---" }
        return String(format: "%.0f", s * CompanionNav.knotsPerMetrePerSecond)
    }

    static func altitude(_ data: CompanionFlightData?) -> String {
        guard let a = data?.altitudeFeet else { return "---" }
        return String(format: "%.0f", a)
    }

    static func track(_ data: CompanionFlightData?) -> String {
        guard let c = data?.courseDegrees else { return "---" }
        return String(format: "%03.0f", c)
    }
}

/// NOW | NEXT, one cell each: the tag and the station on a line, the frequency under it. From an older
/// iPad, its FREQ in the first cell and the second left empty, the line as tall.
struct CompanionNowLineView: View {
    let line: CompanionNowLine
    let onTap: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                switch line {
                case .radio(let now, let next):
                    cell(tag: L10n.Nav.freqCurrent, tint: theme.onTarget, station: now?.station, frequency: now?.frequency)
                    Rectangle().fill(theme.panelStroke).frame(width: 1, height: 36)
                    cell(tag: L10n.Nav.freqNext, tint: theme.info, station: next?.station, frequency: next?.frequency)
                case .freq(let station, let frequency):
                    cell(tag: "FREQ", tint: theme.textSecondary, station: station, frequency: frequency)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.panelStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("read.frequencies")
    }

    private func cell(tag: String, tint: Color, station: String?, frequency: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: tag)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(tint)
                    .fixedSize()
                Text(verbatim: station.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                    .font(.aero(size: CockpitType.label))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            FrequencyLineText(text: frequency ?? "—",
                              font: .aero(size: CockpitType.row, weight: .bold, design: .monospaced),
                              color: theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The page

/// NAV: the DEST line, the legs and the radio in one scroll, Emergency under it, the act band at the foot.
/// The phone Cockpit's ROUTE, from the stream.
struct CompanionNavPage: View {
    let flightData: CompanionFlightData?
    let snapshot: CompanionFlightPlanSnapshot?
    /// The iPad's check slot, from its checklist snapshot; nil from an iPad that sends none.
    let checkSlot: CheckSlot?
    let onCheckSlot: (CheckSlot) -> Void
    /// ✓ DONE's UNDO, sent from the slot, offered for six seconds over the page's foot.
    @Binding var memoryUndo: NavUndoOffer?
    var scale: CockpitScale = .current

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let nav = CompanionNav(flightData: flightData, snapshot: snapshot)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SeparateView { CompanionDestSection(nav: nav, scale: scale) }
                SeparateView { CompanionLegsAndRadio(nav: nav, flightData: flightData) }
                    .frame(maxHeight: .infinity, alignment: .top)
                CompanionEmergencyFoot()
            }
            .overlay(alignment: .bottom) {
                if let offer = memoryUndo {
                    NavUndoToast(offer: offer) { memoryUndo = nil }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            SeparateView {
                CompanionActBand(nav: nav, flightData: flightData, snapshot: snapshot, checkSlot: checkSlot,
                                 onCheckSlot: onCheckSlot, scale: scale)
            }
        }
        .background(theme.background)
    }
}

/// The DEST line, as on ROUTE. No "Resume route" on it: the phone resumes from Divert, which sends again
/// until the iPad takes it (`CompanionDivert.Request`).
struct CompanionDestSection: View {
    let nav: CompanionNav
    var scale: CockpitScale = .current

    var body: some View {
        if let estimate = nav.destination(now: FlightClock.now) {
            OfferedWidth {
                DestinationLine(estimate: estimate, scale: scale, onResumeRoute: nil)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
        }
    }
}

/// LEGS, then RADIO, in one scroll, opened on the leg being flown. The legs are ROUTE's rows; a row says
/// nothing more on a tap here (the phone has no map to frame it on).
struct CompanionLegsAndRadio: View {
    let nav: CompanionNav
    let flightData: CompanionFlightData?

    var body: some View {
        let plan = nav.plan
        let radio = CompanionRadio.stations(flightData: flightData, plan: plan)
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let plan, !plan.waypoints.isEmpty {
                        legs(plan)
                    } else {
                        Text(L10n.Companion.noFlightPlan)
                            .font(.aero(size: CockpitType.label))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !radio.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            CompanionColumnHeader(title: L10n.Route.radio)
                            ForEach(Array(radio.enumerated()), id: \.offset) { _, item in
                                FrequencyRow(item: item, large: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .modifier(SharpScrollEdges())
            .onAppear { reveal(reader, plan: plan) }
            .onChange(of: plan?.currentWaypointIndex) { _, _ in reveal(reader, plan: plan) }
        }
    }

    private func legs(_ plan: FlightPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionColumnHeader(title: L10n.Route.legs)
            ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, _ in
                RouteLegRow(plan: plan, index: index,
                            actual: RouteLegRow.actualTime(plan: plan, index: index,
                                                           legTimer: flightData?.chronometerElapsed ?? 0),
                            onTap: {})
                    .allowsHitTesting(false)
                    .accessibilityRemoveTraits(.isButton)
                    .id(LegsPanelReveal.RowID(index: index))
                if index < plan.waypoints.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                }
            }
        }
    }

    /// The leg being flown into view, on the next turn once the rows are laid out.
    private func reveal(_ reader: ScrollViewProxy, plan: FlightPlan?) {
        guard let plan, let row = LegsPanelReveal.row(currentWaypointIndex: plan.currentWaypointIndex,
                                                      waypointCount: plan.waypoints.count) else { return }
        DispatchQueue.main.async { reader.scrollTo(LegsPanelReveal.RowID(index: row), anchor: nil) }
    }
}

/// LEGS, RADIO: as ROUTE heads its columns.
private struct CompanionColumnHeader: View {
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

/// 121.500, under the scroll and always whole, as on ROUTE.
private struct CompanionEmergencyFoot: View {
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.panelStroke).frame(height: 1)
            FrequencyRow(item: .emergency, large: true)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - The act band

/// The Cockpit's four frames under NAV: the iPad's check slot · START LEG, then MARK · Divert · More. Each
/// slot keeps its frame whatever it holds; one with nothing to do is dimmed, never gone.
struct CompanionActBand: View {
    let nav: CompanionNav
    let flightData: CompanionFlightData?
    let snapshot: CompanionFlightPlanSnapshot?
    let checkSlot: CheckSlot?
    let onCheckSlot: (CheckSlot) -> Void
    var scale: CockpitScale = .current
    /// For the tests: each slot as laid out.
    var onPlace: ((Int, CGRect) -> Void)? = nil

    @EnvironmentObject private var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let metrics = ActBandMetrics.make(layout: .narrow, scale: scale)
        ActBandLayout(metrics: metrics, onPlace: onPlace) {
            slotOne
            CompanionMarkSlot(state: CompanionMarkState.make(plan: nav.plan, flightData: flightData), scale: scale)
            CompanionDivertButton(isEnabled: CompanionDivertButton.isOffered(
                plan: snapshot, currentWaypointIndex: flightData?.currentWaypointIndex))
            CompanionMoreMenu(plan: nav.plan, flightData: flightData)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { theme.panel.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
    }

    /// The iPad's check slot, its room kept from an iPad that sends none.
    @ViewBuilder
    private var slotOne: some View {
        if let checkSlot {
            CheckSlotButton(slot: checkSlot) { onCheckSlot(checkSlot) }
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}

/// START LEG, then MARK with the waypoint and the leg time under it, sent to the iPad: `startChronometer`,
/// then `recordATO` of the waypoint flown to, which starts the next leg's timer there.
struct CompanionMarkSlot: View {
    let state: CompanionMarkState
    var scale: CockpitScale = .current

    @EnvironmentObject private var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        switch state {
        case .unavailable:
            face(title: L10n.Nav.mark, titleLines: 1, lines: [])
                .opacity(0.4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.Nav.mark)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("companion.mark")
        case .startLeg:
            Button { companionConnectivityManager.sendCommand(.startChronometer) } label: {
                face(title: L10n.Nav.startLegTimer, titleLines: 2, lines: [])
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Nav.startLegTimer)
            .accessibilityIdentifier("companion.startLeg")
        case .mark(let index, let name, let legTime):
            Button { companionConnectivityManager.sendCommand(.recordATO(waypointIndex: index)) } label: {
                face(title: L10n.Nav.mark, titleLines: 1, lines: [name, legTime])
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(L10n.Nav.mark) \(name), \(L10n.Nav.leg) \(legTime)")
            .accessibilityIdentifier("companion.mark")
        }
    }

    /// The phone's: the Cockpit's MARK face (`ActMarkButton.phoneBlocks`), set to fit the slot (`ActFace`):
    /// the verb, the waypoint whole (on two lines where it has two words), the leg time. Until 6.2 the
    /// waypoint had one monospaced line at the label size and lost what didn't fit: "SAIGNELÉGIER" was cut
    /// after eight letters. Elsewhere (the tests' iPad), the word at the act band's size over one line each.
    @ViewBuilder
    private func face(title: String, titleLines: Int, lines: [String]) -> some View {
        let buttonSize = CockpitType.button(for: scale)
        Group {
            if scale == .phone {
                ActFaceText(blocks: Self.phoneBlocks(title: title, lines: lines))
            } else {
                VStack(spacing: 2) {
                    Text(verbatim: title)
                        .font(.aero(size: buttonSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(titleLines)
                        .minimumScaleFactor(CockpitType.label(for: scale) / buttonSize)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.aero(size: CockpitType.label(for: scale), weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
        }
        .foregroundColor(theme.actionText)
        .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: ActFace.inset, scale: scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(theme.action))
        .contentShape(Rectangle())
    }
}

extension CompanionMarkSlot {
    /// `lines`: the waypoint, then the leg time, as `CompanionMarkState.mark` gives them.
    static func phoneBlocks(title: String, lines: [String]) -> [ActFaceBlock] {
        ActMarkButton.phoneBlocks(title: title, name: lines.first, time: lines.dropFirst().first)
    }
}

/// More: the leg timer started again after a pause, or reset to zero; the nav log. Every action is the
/// iPad's, sent.
struct CompanionMoreMenu: View {
    let plan: FlightPlan?
    let flightData: CompanionFlightData?

    @EnvironmentObject private var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.cockpitTheme) private var theme
    @State private var showNavLog = false

    var body: some View {
        let running = flightData?.chronometerStartTime != nil
        let started = running || (flightData?.chronometerElapsed ?? 0) > 0.5
        Menu {
            if plan != nil && started {
                if !running {
                    Button { companionConnectivityManager.sendCommand(.startChronometer) } label: {
                        Label(L10n.Nav.startChronometer, systemImage: "play.fill")
                    }
                }
                Button(role: .destructive) { companionConnectivityManager.sendCommand(.resetChronometer) } label: {
                    Label(L10n.Nav.resetChronometer, systemImage: "arrow.counterclockwise")
                }
            }
            Button { showNavLog = true } label: {
                Label(L10n.Nav.navLog, systemImage: "list.clipboard")
            }
            .disabled(plan == nil)
        } label: {
            ActNarrowLabel(icon: "ellipsis.circle", title: L10n.Nav.more, tint: theme.action)
        }
        .accessibilityLabel(L10n.Nav.more)
        .accessibilityIdentifier("companion.more")
        .sheet(isPresented: $showNavLog) {
            CompanionNavLogSheet(onClose: { showNavLog = false })
                .environment(\.cockpitTheme, theme)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - The nav log

/// The whole route as a table, from More: per waypoint, the leg arriving at it (MC, NM), its ETO and its
/// ATO, the one flown to marked. A row is the leg ending at its waypoint, as on the printed nav log and the
/// legs (the PLAN disclosure it replaces read the leg leaving it, and the ETO of the waypoint after). A
/// tap on a waypoint's empty ATO records it now, as the PLAN always allowed. (6.2.0)
struct CompanionNavLogSheet: View {
    let onClose: () -> Void

    @EnvironmentObject private var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var plan: CompanionFlightPlanSnapshot? { companionConnectivityManager.lastFlightPlanSnapshot }
    private var flightData: CompanionFlightData? { companionConnectivityManager.lastReceivedData }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Nav.navLog)
                    .font(.aero(size: CockpitType.row, weight: .bold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Button(L10n.Button.close) { onClose() }
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(theme.action)
                    .frame(minWidth: CockpitTarget.control, minHeight: CockpitTarget.control)
                    .accessibilityIdentifier("companionNavLog.close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if let plan {
                header
                table(FlightPlan(companion: plan, currentWaypointIndex: flightData?.currentWaypointIndex))
            }
            Spacer(minLength: 0)
        }
        .background(theme.background.ignoresSafeArea())
    }

    /// The columns' names: ICAO's, in every language.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                Text(verbatim: column.title)
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: column.width)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityHidden(true)
    }

    private static let columns: [(title: String, width: CGFloat)] = [("MC", 44), ("NM", 52), ("ETO", 60), ("ATO", 60)]

    private func table(_ plan: FlightPlan) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wp in
                        row(index: index, waypoint: wp, plan: plan).id(index)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onAppear { proxy.scrollTo(plan.currentWaypointIndex, anchor: .center) }
            .onChange(of: plan.currentWaypointIndex) { _, index in
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(index, anchor: .center) } // (UX-18)
            }
        }
    }

    private func row(index: Int, waypoint wp: FlightPlanWaypoint, plan: FlightPlan) -> some View {
        let isCurrent = index == plan.currentWaypointIndex
        let isPast = index < plan.currentWaypointIndex
        let leg = plan.legArriving(at: index)
        let textColor: Color = isPast ? theme.textSecondary : theme.textPrimary.opacity(isCurrent ? 1 : 0.8)
        let font = Font.aero(size: CockpitType.label, design: .monospaced)
        return HStack(spacing: 0) {
            Group {
                if isPast { Image(systemName: "checkmark").font(.aero(size: CockpitType.label)).foregroundColor(theme.onTarget) }
                else if isCurrent { Image(systemName: "arrowtriangle.right.fill").font(.aero(size: CockpitType.label)).foregroundColor(theme.route) }
                else { Text("\(index + 1)").font(font).foregroundColor(theme.textSecondary) }
            }
            .frame(width: 28)
            // The label size throughout: the name takes what the four figures leave. (v6.0 review)
            Text(wp.name.isEmpty ? "WP\(index)" : wp.name)
                .font(.aero(size: CockpitType.label, weight: isCurrent ? .bold : .regular, design: .monospaced))
                .foregroundColor(isCurrent ? theme.route : textColor)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(leg?.magneticCourse.map { String(format: "%03.0f", $0) } ?? "---").font(font).foregroundColor(textColor).frame(width: 44)
            Text(leg?.distance.map { String(format: "%.1f", $0) } ?? "---").font(font).foregroundColor(textColor).frame(width: 52)
            Text(time(plan.estimatedTimeOver(at: index))).font(font).foregroundColor(textColor).frame(width: 60)
            Button {
                if wp.actualTimeOver == nil { companionConnectivityManager.sendCommand(.recordATO(waypointIndex: index)) }
            } label: {
                Text(time(wp.actualTimeOver))
                    .font(.aero(size: CockpitType.label, weight: wp.actualTimeOver != nil ? .bold : .regular, design: .monospaced))
                    .foregroundColor(wp.actualTimeOver != nil ? theme.onTarget : theme.action)
                    .frame(width: 60)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(wp.actualTimeOver != nil)
        }
        .padding(.vertical, 2)
        .background(isCurrent ? theme.action.opacity(0.1) : Color.clear)
    }

    private func time(_ date: Date?) -> String {
        CompanionClock.text(date, utc: flightData?.alwaysUseUTC == true)
    }
}

/// "13:07", in UTC when the iPad says so: the times the phone writes (the nav log, the landed card).
enum CompanionClock {
    // Cached: the nav log writes two per row while the stream redraws it every second, and a
    // DateFormatter is among the most expensive Foundation allocations. (efficiency)
    private static let local: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let utc: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    static func text(_ date: Date?, utc useUTC: Bool) -> String {
        guard let date else { return "--:--" }
        return (useUTC ? utc : local).string(from: date)
    }
}
