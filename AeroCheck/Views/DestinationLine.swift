import SwiftUI

// MARK: - The DEST line (6.2.0)

/// ROUTE's first line: the destination, the distance and the time still to fly, the ETA over it and how
/// far off the plan that is, with the route drawn to scale under the figures. Also meant for Plan › Map's
/// legs panel (in place of the bar and the dots) and the Companion's NAV screen. Everything it shows
/// comes from `DestinationEstimate`; the view decides nothing.
///
/// - iPad: "DEST" and the ident on the left; the distance, the ETE, "ETA hh:mm" and Δ on the right, on
///   one line.
/// - Phone: the ident and Δ on one line, the distance, the ETE and the ETA on the next. At 17 pt the
///   proposal's single line ("DEST LSZB 71 NM · 41 min · 11:58 ▼3", drawn at 14) can't hold a
///   12-letter field and a 12-hour clock in 378 pt.
/// - Below 30 kt there is no ETE, ETA or Δ: the plan's "ETO hh:mm" instead. Diverting, DEST is the
///   field straight there, no track, and "Resume route" sits where the track was. Once the destination
///   is marked, the final Δ.
///
/// Every figure sits in a cell as wide as the widest value its format gives (the hidden templates), so
/// nothing moves when a figure changes, appears or goes; Δ keeps its room when there is none. The line
/// keeps one height in every state that shows the same rows: the track's row, or the button's while
/// diverting (`DestinationLineTests`).
struct DestinationLine: View {
    let estimate: DestinationEstimate
    let scale: CockpitScale
    /// Back to the route, while diverting. Nil: no button (a viewer that can't change the plan), and the
    /// line keeps the track's height.
    let onResumeRoute: (() -> Void)?
    /// The language the line reads in, "fr"; nil, the app's. For the French previews and tests.
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            figures
            lowerRow
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var metrics: Metrics { Metrics(scale) }

    // MARK: The figures

    /// One element for VoiceOver, a whole sentence. Its value is the Flight Log's DEST ETO, which the
    /// replay UI tests compare with the Flight Log after the flight (eet-3, eet-4).
    private var figures: some View {
        Group {
            if scale == .phone {
                phoneFigures
            } else {
                kneeboardFigures
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DestinationSpeech.line(estimate, language: language))
        .accessibilityValue(DestinationSpeech.testHook(estimate))
        .accessibilityIdentifier("dest.line")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var kneeboardFigures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            destination
            Spacer(minLength: metrics.minimumGap)
            HStack(alignment: .firstTextBaseline, spacing: metrics.figureGap) {
                distanceCell
                eteCell
                clockCell
                deltaCell
            }
        }
    }

    private var phoneFigures: some View {
        VStack(alignment: .trailing, spacing: metrics.phoneLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                destination
                Spacer(minLength: metrics.minimumGap)
                deltaCell
            }
            HStack(alignment: .firstTextBaseline, spacing: metrics.figureGap) {
                distanceCell
                separator
                eteCell
                separator
                clockCell
            }
        }
    }

    /// "DEST" and the field. Amber while diverting, as the act band's Divert is. The ident is what gives
    /// way in a window narrower than the line was made for (an iPad mini), never the figures.
    private var destination: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.labelGap) {
            Text(verbatim: "DEST")
                .font(.aero(size: metrics.labelSize, weight: .semibold))
                .foregroundColor(estimate.kind == .diversion ? theme.warning : theme.textSecondary)
            Text(verbatim: estimate.ident)
                .font(.aero(size: metrics.identSize, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var distanceCell: some View {
        DestinationFigureCell(text: DestinationLine.distanceText(estimate), widest: DestinationLine.distanceTemplates,
                              font: figureFont, color: theme.textPrimary)
    }

    private var eteCell: some View {
        DestinationFigureCell(text: DestinationLine.eteText(estimate), widest: DestinationLine.eteTemplates,
                              font: figureFont, color: theme.textPrimary)
    }

    private var clockCell: some View {
        DestinationFigureCell(text: DestinationLine.clockText(estimate), widest: DestinationLine.clockTemplates,
                              font: figureFont, color: theme.textPrimary)
    }

    /// Δ, or its room left empty: below 30 kt, with no fix, while diverting.
    private var deltaCell: some View {
        let delta = estimate.delta.map(DestinationFormat.delta)
        return DestinationFigureCell(text: delta?.text ?? "", widest: DestinationLine.deltaTemplates,
                                     font: .aero(size: metrics.figureSize, weight: .bold, design: .monospaced),
                                     color: delta.map { color(for: $0.tone) } ?? theme.textSecondary)
    }

    private var separator: some View {
        Text(verbatim: "·")
            .font(figureFont)
            .foregroundColor(theme.textDim)
            .accessibilityHidden(true)
    }

    private var figureFont: Font { .aero(size: metrics.figureSize, design: .monospaced) }

    /// The leg rows' colours: ahead in the theme's on-target colour, behind in its caution colour.
    private func color(for tone: DestinationFormat.Tone) -> Color {
        switch tone {
        case .ahead: return theme.onTarget
        case .behind: return theme.warning
        case .even: return theme.textSecondary
        }
    }

    // MARK: The track's row

    /// The route to scale; "Resume route" in its place while diverting; or its room, empty.
    @ViewBuilder
    private var lowerRow: some View {
        if estimate.kind == .diversion, let onResumeRoute {
            resumeRouteButton(onResumeRoute)
        } else if let track = estimate.track {
            RouteTrackBar(track: track, nextIdent: estimate.nextIdent, scale: scale, language: language)
        } else {
            Color.clear
                .frame(height: metrics.track.rowHeight)
                .accessibilityHidden(true)
        }
    }

    /// As the map's card draws it: outlined, in the colour of what can be touched, at the right.
    private func resumeRouteButton(_ action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: action) {
                Text(L10n.Dest.resumeRoute(language: language))
                    .font(.aero(size: metrics.labelSize, weight: .bold))
                    .foregroundColor(theme.action)
                    .lineLimit(1)
                    .padding(.horizontal, metrics.buttonPadding)
                    .frame(minHeight: metrics.resumeHeight)
                    .overlay(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("dest.resumeRoute")
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius)
            .fill(theme.card)
            .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius).strokeBorder(theme.panelStroke, lineWidth: 1))
    }
}

// MARK: - The line's text and sizes

extension DestinationLine {
    /// "83 NM"; "—" diverting with no fix.
    static func distanceText(_ estimate: DestinationEstimate) -> String {
        estimate.remainingNM.map(DestinationFormat.distance) ?? "—"
    }

    /// "41 min", "1:05 h"; "—" below 30 kt, with no fix, or with a planned EET missing.
    static func eteText(_ estimate: DestinationEstimate) -> String {
        estimate.ete.map(Self.ete) ?? "—"
    }

    /// "ETA 11:58" when there is a live ETA, else the plan's "ETO 11:55", else "ETA —" (diverting, slow).
    static func clockText(_ estimate: DestinationEstimate) -> String {
        if let eta = estimate.eta { return "ETA " + DestinationFormat.clock(eta) }
        if let eto = estimate.plannedETO { return "ETO " + DestinationFormat.clock(eto) }
        return "ETA —"
    }

    private static func ete(_ seconds: TimeInterval) -> String {
        "\(DestinationFormat.eteValue(seconds)) \(DestinationFormat.eteUnit(seconds))"
    }

    /// Each cell's widest values. B612 Mono draws every character the same width, so "888 NM" is as wide
    /// as any three-digit distance; "—" is there in case it comes from another font, taller.
    static let distanceTemplates = [DestinationFormat.distance(888), "—"]
    /// Both forms of the ETE: up to 59 min, then up to 9:59 h.
    static var eteTemplates: [String] { [ete(59 * 60), ete(599 * 60), "—"] }
    /// A clock time with two digits to its hour, and AM or PM where the device writes them.
    static var clockTemplates: [String] {
        let widest = NextWaypointReadout.widestETA
        return ["ETA " + widest, "ETO " + widest, "ETA —"]
    }
    /// Up to 99 minutes either way; more scales down inside the cell.
    static let deltaTemplates = ["▲88", "▼88", "±0"]

    /// The line's sizes. In-flight text is never under `CockpitType.label`: 20 pt on the iPad, 17 on
    /// the phone.
    struct Metrics {
        let labelSize: CGFloat
        let identSize: CGFloat
        let figureSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let rowSpacing: CGFloat
        let phoneLineSpacing: CGFloat
        let labelGap: CGFloat
        let figureGap: CGFloat
        let minimumGap: CGFloat
        let cornerRadius: CGFloat
        /// "Resume route": the map card's 52 pt on the iPad, the phone's next line's 44.
        let resumeHeight: CGFloat
        let buttonPadding: CGFloat
        let track: RouteTrackBar.Metrics

        init(_ scale: CockpitScale) {
            let kneeboard = scale == .kneeboard
            labelSize = CockpitType.label(for: scale)
            identSize = CockpitType.size(kneeboard: 24, phone: 20, scale: scale)
            figureSize = CockpitType.size(kneeboard: 24, phone: 17, scale: scale)
            horizontalPadding = kneeboard ? 16 : 12
            verticalPadding = kneeboard ? 12 : 10
            rowSpacing = kneeboard ? 10 : 8
            phoneLineSpacing = 4
            labelGap = kneeboard ? 12 : 8
            figureGap = kneeboard ? 20 : 6
            minimumGap = kneeboard ? 16 : 8
            cornerRadius = kneeboard ? 14 : 12
            resumeHeight = kneeboard ? 52 : 44
            buttonPadding = kneeboard ? 16 : 12
            track = RouteTrackBar.Metrics(scale)
        }
    }
}

/// A figure in a cell as wide as the widest value its format gives, at the cell's right edge: so
/// 10 → 9 NM, 59 min → 1:00 h or a figure → "—" moves nothing beside it (as `NavValueCell` does on the
/// map's card).
struct DestinationFigureCell: View {
    let text: String
    let widest: [String]
    let font: Font
    let color: Color

    var body: some View {
        ZStack(alignment: .trailing) {
            ForEach(widest, id: \.self) { Text(verbatim: $0) }
        }
        .font(font)
        .hidden()
        .accessibilityHidden(true)
        .overlay(alignment: .trailing) {
            Text(verbatim: text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .fixedSize()
    }
}

// MARK: - The route to scale

/// The route drawn to scale under the DEST line (`RouteTrack`): the flown part filled, a 2 pt notch where
/// each waypoint really lies (the next one magenta and taller), the aircraft as a small ▶ at the flown
/// fraction. One element for VoiceOver: "12 of 83 NM flown, next LSGC".
struct RouteTrackBar: View {
    let track: RouteTrack
    let nextIdent: String?
    let scale: CockpitScale
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    /// The track's sizes: 6 pt high on the iPad, 5 on the phone.
    struct Metrics: Equatable {
        let barHeight: CGFloat
        let notchWidth: CGFloat = 2
        let notchHeight: CGFloat
        let nextNotchHeight: CGFloat
        let aircraftSize: CGFloat

        init(_ scale: CockpitScale) {
            let kneeboard = scale == .kneeboard
            barHeight = kneeboard ? 6 : 5
            notchHeight = kneeboard ? 16 : 13
            nextNotchHeight = kneeboard ? 24 : 19
            aircraftSize = kneeboard ? 18 : 15
        }

        var rowHeight: CGFloat { max(nextNotchHeight, aircraftSize) }
        /// The ends of the track sit half an aircraft in, so the ▶ is whole at either end.
        var inset: CGFloat { aircraftSize / 2 }
    }

    /// Where everything goes along a row `width` wide: x of each notch, of the aircraft, of the track's ends.
    struct Placement: Equatable {
        let notches: [CGFloat]
        let next: Int?
        let aircraft: CGFloat
        let start: CGFloat
        let end: CGFloat
    }

    static func placement(_ track: RouteTrack, width: CGFloat, metrics: Metrics) -> Placement {
        let start = metrics.inset
        let length = max(0, width - 2 * metrics.inset)
        let x = { (fraction: Double) in start + CGFloat(min(max(fraction, 0), 1)) * length }
        return Placement(notches: track.notches.map(x), next: track.nextIndex, aircraft: x(track.flown),
                         start: start, end: start + length)
    }

    var body: some View {
        let metrics = Metrics(scale)
        let palette = theme
        Canvas { context, size in
            Self.draw(track, in: &context, size: size, metrics: metrics, theme: palette)
        }
        .frame(height: metrics.rowHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Self.spoken(track, next: nextIdent, language: language))
        .accessibilityIdentifier("dest.track")
    }

    private static func draw(_ track: RouteTrack, in context: inout GraphicsContext, size: CGSize, metrics: Metrics,
                             theme: CockpitTheme) {
        let place = placement(track, width: size.width, metrics: metrics)
        let mid = size.height / 2
        let bar = metrics.barHeight
        // The route, then the part flown over it.
        context.fill(Path(roundedRect: CGRect(x: place.start, y: mid - bar / 2, width: place.end - place.start, height: bar),
                          cornerRadius: bar / 2),
                     with: .color(theme.textDim.opacity(0.4)))
        if place.aircraft > place.start {
            context.fill(Path(roundedRect: CGRect(x: place.start, y: mid - bar / 2, width: place.aircraft - place.start, height: bar),
                              cornerRadius: bar / 2),
                         with: .color(theme.onTarget))
        }
        // The notches, the next one last so nothing covers it.
        for (index, x) in place.notches.enumerated() where index != place.next {
            context.fill(notch(at: x, height: metrics.notchHeight, mid: mid, metrics: metrics), with: .color(theme.textSecondary))
        }
        if let next = place.next, place.notches.indices.contains(next) {
            context.fill(notch(at: place.notches[next], height: metrics.nextNotchHeight, mid: mid, metrics: metrics),
                         with: .color(theme.route))
        }
        // The aircraft, outlined so it reads over a notch.
        let ownship = aircraft(at: place.aircraft, mid: mid, size: metrics.aircraftSize)
        context.fill(ownship, with: .color(theme.textPrimary))
        context.stroke(ownship, with: .color(theme.background), lineWidth: 1.5)
    }

    private static func notch(at x: CGFloat, height: CGFloat, mid: CGFloat, metrics: Metrics) -> Path {
        Path(CGRect(x: x - metrics.notchWidth / 2, y: mid - height / 2, width: metrics.notchWidth, height: height))
    }

    /// ▶, its box centred on the aircraft's place.
    private static func aircraft(at x: CGFloat, mid: CGFloat, size: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x - size / 2, y: mid - size / 2))
        path.addLine(to: CGPoint(x: x + size / 2, y: mid))
        path.addLine(to: CGPoint(x: x - size / 2, y: mid + size / 2))
        path.closeSubpath()
        return path
    }

    /// "12 of 83 NM flown, next LSGC"; "83 of 83 NM flown" once the destination is marked.
    static func spoken(_ track: RouteTrack, next: String?, language: String?) -> String {
        let flown = track.flownNM.safeRoundedInt(or: 0)
        let total = track.totalNM.safeRoundedInt(or: 0)
        if track.nextIndex != nil, let next {
            return L10n.Dest.trackFlown(flown, of: total, next: next, language: language)
        }
        return L10n.Dest.trackFlown(flown, of: total, language: language)
    }
}

// MARK: - What VoiceOver reads

/// The DEST line in words: "Destination LSZB, 71 nautical miles, 41 minutes, overhead at 11:58, 3 minutes
/// behind the plan. Planned arrival", then its value, the Flight Log's DEST ETO. Distances and durations
/// are spelt out in the line's language by Foundation, so VoiceOver never reads "N M" or "min".
enum DestinationSpeech {
    static func line(_ estimate: DestinationEstimate, language: String?) -> String {
        var parts: [String] = []
        switch estimate.kind {
        case .route: parts.append(L10n.Dest.destination(estimate.ident, language: language))
        case .diversion: parts.append(L10n.Dest.divertingTo(estimate.ident, language: language))
        case .completed: parts.append(L10n.Dest.reached(estimate.ident, language: language))
        }
        if estimate.kind != .completed, let distance = estimate.remainingNM {
            parts.append(Self.distance(distance, language: language))
        }
        if let ete = estimate.ete {
            parts.append(duration(minutes: (ete / 60).safeRoundedInt(or: 0), language: language))
        }
        if let eta = estimate.eta {
            parts.append(L10n.Dest.overhead(DestinationFormat.clock(eta), language: language))
        } else if let eto = estimate.plannedETO {
            parts.append(L10n.Dest.plannedOverhead(DestinationFormat.clock(eto), language: language))
        }
        if let delta = estimate.delta {
            parts.append(self.delta(delta, language: language))
        }
        let sentence = parts.joined(separator: ", ")
        return testHook(estimate).isEmpty ? sentence : sentence + ". " + L10n.Dest.plannedArrival(language: language)
    }

    /// The Flight Log's DEST ETO, as the device writes a time: what the replay UI tests read (eet-3,
    /// eet-4), as they read today's "ETA" under the legs. None while diverting: it isn't the field's.
    static func testHook(_ estimate: DestinationEstimate) -> String {
        guard estimate.kind != .diversion, let eto = estimate.plannedDestinationETO else { return "" }
        return DestinationFormat.clock(eto)
    }

    /// Δ in whole minutes, the line's own rounding: "3 minutes behind the plan", "on time".
    static func delta(_ seconds: TimeInterval, language: String?) -> String {
        let shown = DestinationFormat.delta(seconds)
        let minutes = Int(shown.text.dropFirst()) ?? 0
        switch shown.tone {
        case .ahead: return L10n.Dest.ahead(duration(minutes: minutes, language: language), language: language)
        case .behind: return L10n.Dest.behind(duration(minutes: minutes, language: language), language: language)
        case .even: return L10n.Dest.onTime(language: language)
        }
    }

    /// "71 nautical miles", "71 milles marins": the figure the line shows, rounded as it rounds it.
    static func distance(_ nauticalMiles: Double, language: String?) -> String {
        let shown = DestinationFormat.distance(nauticalMiles).split(separator: " ").first.flatMap { Double($0) }
        let formatter = MeasurementFormatter()
        formatter.locale = locale(language)
        formatter.unitStyle = .long
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: shown ?? nauticalMiles.rounded(), unit: UnitLength.nauticalMiles))
    }

    /// "41 minutes", "1 hour, 5 minutes".
    static func duration(minutes: Int, language: String?) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale(language)
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = minutes == 0 ? .default : .dropAll
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }

    private static func locale(_ language: String?) -> Locale {
        Locale(identifier: language ?? Bundle.main.preferredLocalizations.first ?? "en")
    }
}

// MARK: - Previews

#if DEBUG
/// The proposal's route, for the previews and the tests: LSZQ → LSGC 29.6 NM → LSGN 8.1 → SAIGNELÉGIER 7.5
/// → FRIBOURG 11.3 → LSZB 26.1 (82.6 NM). At 11:17:20 on the leg to LSGC, 17.6 NM from it at 104 kt:
/// 71 NM, 41 min, ETA 11:58 against the plan's 11:55, so ▼3; 12 of 83 NM flown.
enum DestinationLineSample {
    /// Today at that time, on the device's clock.
    static func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: Date()) ?? Date()
    }

    static func route(next: Int = 1, live: Double? = 17.6, gs: Double = 104,
                      now: Date = DestinationLineSample.at(11, 17, 20),
                      plannedOver: Date = DestinationLineSample.at(11, 55), atoOverDestination: Date? = nil,
                      diversion: String? = nil) -> DestinationEstimate {
        let input = DestinationInput(names: ["LSZQ", "LSGC", "LSGN", "SAIGNELÉGIER", "FRIBOURG", "LSZB"],
                                     legDistanceNM: [nil, 29.6, 8.1, 7.5, 11.3, 26.1],
                                     legEET: [nil, 1_380, 282, 258, 390, 905],
                                     nextIndex: next,
                                     plannedOverDestination: plannedOver,
                                     plannedDestinationETO: plannedOver.addingTimeInterval(300),
                                     destinationATO: atoOverDestination,
                                     diversionIdent: diversion,
                                     liveDistanceNM: live,
                                     groundSpeedKnots: gs,
                                     now: now)
        return DestinationEstimator.estimate(input)!
    }

    /// The widest the line gets: a 12-letter field, three-digit NM, "1:05 h" and an evening ETA, ▼12.
    static func long(diverting: Bool = false) -> DestinationEstimate {
        let input = DestinationInput(names: ["LSZQ", "LSGC", "FRIBOURG", "SAIGNELÉGIER"],
                                     legDistanceNM: [nil, 30, 45, 35],
                                     legEET: [nil, 1_500, 1_500, 1_500],
                                     nextIndex: 1,
                                     plannedOverDestination: at(22, 46),
                                     plannedDestinationETO: at(22, 51),
                                     destinationATO: nil,
                                     diversionIdent: diverting ? "SAIGNELÉGIER" : nil,
                                     liveDistanceNM: diverting ? 105 : 25,
                                     groundSpeedKnots: diverting ? 97 : 100,
                                     now: at(21, 53))
        return DestinationEstimator.estimate(input)!
    }

    static var behind: DestinationEstimate { route() }
    static var ahead: DestinationEstimate { route(plannedOver: at(12, 0)) }
    /// Taxiing out, the departure not marked yet: the plan's ETO, no Δ.
    static var slow: DestinationEstimate { route(next: 0, live: 0.3, gs: 8, now: at(10, 50)) }
    static var diverting: DestinationEstimate { route(live: 12.4, diversion: "LSZG") }
    static var completed: DestinationEstimate {
        route(next: 6, live: nil, gs: 0, now: at(12, 4), atoOverDestination: at(11, 53))
    }

    /// The previews' and the renders' states, with their names.
    static var states: [(name: String, estimate: DestinationEstimate)] {
        [("ahead", ahead), ("behind", behind), ("slow", slow), ("diverting", diverting),
         ("completed", completed), ("long", long())]
    }
}

/// Every state of the line, one under the other, as ROUTE would show it.
private struct DestinationLinePreview: View {
    let scale: CockpitScale
    var language: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(DestinationLineSample.states, id: \.name) { state in
                    DestinationLine(estimate: state.estimate, scale: scale, onResumeRoute: {}, language: language)
                }
            }
            .padding(scale == .kneeboard ? 16 : 12)
        }
        .frame(width: scale == .kneeboard ? 820 : 402)
        .background(CockpitTheme.day.background)
    }
}

#Preview("iPad") { DestinationLinePreview(scale: .kneeboard) }
#Preview("iPad, French") { DestinationLinePreview(scale: .kneeboard, language: "fr") }
#Preview("Phone") { DestinationLinePreview(scale: .phone) }
#Preview("Phone, French") { DestinationLinePreview(scale: .phone, language: "fr") }
#endif
