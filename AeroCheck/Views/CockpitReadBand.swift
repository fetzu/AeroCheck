import SwiftUI

// MARK: - The read band (6.2.0)
//
// What the pilot reads over every Cockpit page, CHECKLIST, MAP and ROUTE alike, under the header and
// the phase bar:
//
//   iPad   the strip, GS · ALT · TRK · NEXT, NEXT with its figures (`StripNextCell`); then NOW | NEXT,
//          the two frequencies on one line each (`ReadBandFrequencies`)
//   phone  the strip, GS · ALT · TRK, its vertical speed beside ALT's label; then the next line, the
//          waypoint, its distance and its ETE on one line (`ReadBandColumnNextLine`), and the NOW line
//          (`ReadBandNowLine`), on one card. The Companion's NAV screen keeps the two-row next line
//          (`ReadBandNextLine`), with its turn arrow
//   phone on its side, in its column (6.2, PR 5): the strip at 28 pt; then the waypoint, its distance
//          and its ETE on one line (`ReadBandColumnNextLine`) over the NOW line; under 400 pt tall, the
//          waypoint, its ETE and NOW on one line (`ReadBandMergedLine`)
//
// A tap on NEXT, on NOW | NEXT or on either line opens ROUTE; on a route's radio timeline a tap on NEXT's
// frequency switches to it instead, and the phone's NOW line does while NEXT is due (6.4.3, the frequency
// handover: `RadioHandover`). Until 6.2 the next waypoint was a card
// over the chart (a line on the phone) and NOW | NEXT a card at its foot: they were on MAP only, and NOW
// and NEXT followed the map's region rather than the flight.
//
// Every figure sits in a cell as wide as the widest value its format gives (`DestinationFigureCell`'s
// hidden templates), "—" where there is none yet, so nothing moves when a figure changes, appears or
// goes, when a name is long, or when a diversion starts: the band keeps one height and every cell its
// frame (`ReadBandLayoutTests`). Text is never under `CockpitType.label`.

/// The read band's rows under the phase bar: the strip (with NEXT on the iPad), then NOW | NEXT (the iPad)
/// or the next line and the NOW line (the phone and any window under 600 pt, the phone's column on its
/// side). Plain values in, so the tests lay out every state. `strip` nil: a phase without it
/// (`CockpitStripRule`); on the phone the next line goes with it, NOW stays, from START FLIGHT on.
struct CockpitReadRows: View {
    let layout: CockpitLayout
    /// The phone's column on its side, under 400 pt tall: the next line and the NOW line on one line
    /// (`CockpitColumnRule`). (6.2, PR 5)
    var mergesLines = false
    var scale: CockpitScale = .current
    let strip: StripReading?
    let next: NextFigures
    let now: PhaseFrequency?
    let nextFrequency: PhaseFrequency?
    /// ROUTE, from a tap on NEXT, on the frequencies or on either line.
    let onShowRoute: () -> Void
    /// ROUTE on its RADIO list, from a tap on the phone's NOW line (`RouteListSwitch`); nil, `onShowRoute`.
    /// (6.2.0)
    var onShowRadio: (() -> Void)? = nil
    /// A tap on NEXT's frequency, and on the phone's NOW line while NEXT is due: the switch (a LISTEN heard).
    /// Nil off a route's timeline: ROUTE, as before. (6.4.3)
    var onNextTap: (() -> Void)? = nil
    /// V-SPEEDS, from a tap on GS.
    var onSpeedTap: (() -> Void)? = nil
    /// The language the band reads in, "fr"; nil, the app's. For the French previews and tests.
    var language: String? = nil
    /// For the tests: each part of the band as laid out, in its space.
    var onLayout: ((ReadBandPart, CGRect) -> Void)? = nil

    @Environment(\.cockpitTheme) private var theme

    static let space = "readBand"

    private var wide: Bool { layout == .wide }
    private var metrics: ReadBandMetrics { ReadBandMetrics(scale) }

    var body: some View {
        VStack(spacing: layout == .columns ? ReadBandMetrics.columnRowGap : metrics.rowGap) {
            if let strip {
                CockpitInstrumentStrip(
                    speedKnots: strip.speedKnots, targetSpeed: strip.targetSpeed,
                    gpsSignalStatus: strip.gpsSignalStatus, altitudeFeet: strip.altitudeFeet,
                    headingDegrees: strip.headingDegrees, verticalSpeedFPM: strip.verticalSpeedFPM,
                    kneeboard: true, next: wide ? next : nil, onNextTap: onShowRoute,
                    onSpeedTap: onSpeedTap, language: language, compact: layout == .columns,
                    tight: layout == .narrow)
                    .readBandPart(.strip)
            }
            switch layout {
            case .wide:
                ReadBandFrequencies(now: now, next: nextFrequency, scale: scale, onTap: onShowRoute,
                                    onNowTap: onShowRadio, onNextTap: onNextTap, language: language)
            case .narrow:
                phoneCard
            case .columns:
                columnCard
            }
        }
        .padding(.horizontal, wide ? 16 : 12)
        .readBandPart(.rows)
        .coordinateSpace(name: Self.space)
        .environment(\.readBandReporter, onLayout)
    }

    /// The next line (with the strip) and the NOW line, on one card. The next line is the column's, one
    /// line: the name, its distance and its ETE. The two rows it had (NEXT over the name, the bearing, the
    /// distance, the ETE and the ETA beside them) left an iPhone's MAP about 290 pt of chart and ROUTE a
    /// leg and a half; the bearing and the ETA are on ROUTE. (6.2.0, device check 11 Oct)
    private var phoneCard: some View {
        VStack(spacing: 0) {
            if strip != nil {
                ReadBandColumnNextLine(figures: next, scale: scale, onTap: onShowRoute, language: language)
                Rectangle().fill(theme.glassStroke).frame(height: 0.5)
                    .padding(.horizontal, metrics.cellPadding)
            }
            nowLine
        }
        .background(theme.glassFill, in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius).strokeBorder(theme.glassStroke, lineWidth: 0.5))
    }

    /// NEXT while it is due and a tap switches to it: the phone's NOW line shows it beside NOW. (6.4.3, q8)
    private var dueNext: PhaseFrequency? {
        guard onNextTap != nil, let nextFrequency, nextFrequency.due else { return nil }
        return nextFrequency
    }

    /// The phone's NOW line: a tap opens ROUTE › RADIO, or switches while NEXT is due beside NOW.
    private var nowLine: some View {
        ReadBandNowLine(now: now, dueNext: dueNext, scale: scale,
                        onTap: (dueNext == nil ? nil : onNextTap) ?? onShowRadio ?? onShowRoute, language: language)
    }

    /// The phone's column on its side: the next line and the NOW line one line each, or merged into one
    /// under 400 pt tall. Each a line, where the portrait card's next line is two rows: the column had
    /// the height for neither. With no strip (before the taxi), NOW alone.
    private var columnCard: some View {
        VStack(spacing: 0) {
            if mergesLines {
                ReadBandMergedLine(figures: strip == nil ? nil : next, now: now, dueNext: dueNext, scale: scale,
                                   onTap: onShowRoute, onNowTap: (dueNext == nil ? nil : onNextTap) ?? onShowRadio,
                                   language: language)
            } else {
                if strip != nil {
                    ReadBandColumnNextLine(figures: next, scale: scale, onTap: onShowRoute, language: language)
                    Rectangle().fill(theme.glassStroke).frame(height: 0.5)
                        .padding(.horizontal, metrics.cellPadding)
                }
                nowLine
            }
        }
        .background(theme.glassFill, in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius).strokeBorder(theme.glassStroke, lineWidth: 0.5))
    }
}

/// How the phone's column on its side reads, from the room it has. Pure, so it is tested without a view.
/// (6.2, PR 5)
enum CockpitColumnRule {
    /// Under 400 pt tall (an iPhone 17e's 370 above the home indicator, a 17's 382), the next line and the
    /// NOW line are one line: with the header, the picker, the strip and the act band's 2 × 2, there is
    /// room for one and not two. A Pro Max (420) has both. The author's answer to the plan's Q2.
    static func mergesNextAndNow(height: CGFloat) -> Bool { height < 400 }
}

/// The strip's live values, as `CockpitInstrumentStrip` takes them.
struct StripReading: Equatable {
    var speedKnots: Double
    var targetSpeed: Int?
    var gpsSignalStatus: GPSSignalStatus
    var altitudeFeet: Double
    var headingDegrees: Double?
    var verticalSpeedFPM: Double?

    /// The strip's GPS state: a flight that isn't recording is lost whatever the signal, as MAP's status
    /// slot and the iPad's header say it (`CockpitStatusRule.gpsAlarm`), so the strip shows the failure flag
    /// a lost signal shows (the red X, the figures hidden). Its figures were the last ones the track had,
    /// and the logbook's times come from that track; on the phones, which have no GPS chip since 6.2.0,
    /// only MAP said it. (6.3.0, the author: a customary flag, on every page and both devices)
    static func gpsStatus(isFlightActive: Bool, isTracking: Bool, signal: GPSSignalStatus) -> GPSSignalStatus {
        isFlightActive && !isTracking ? .lost : signal
    }
}

// MARK: - Sizes

/// The band's sizes. In-flight text is never under `CockpitType.label`: 20 pt on the iPad, 17 on the phone.
struct ReadBandMetrics: Equatable {
    /// "NEXT", the tags, the stations.
    let labelSize: CGFloat
    /// The figures beside the waypoint: BRG, DIST, ETE, ETA.
    let figureSize: CGFloat
    /// The waypoint's name, at most; it scales down to `labelSize` before it is ever cut.
    let identSize: CGFloat
    /// A frequency on NOW | NEXT and on the NOW line.
    let frequencySize: CGFloat
    let cellPadding: CGFloat
    let verticalPadding: CGFloat
    let rowGap: CGFloat
    let figureGap: CGFloat
    let cornerRadius: CGFloat

    init(_ scale: CockpitScale) {
        let kneeboard = scale == .kneeboard
        labelSize = CockpitType.label(for: scale)
        figureSize = CockpitType.label(for: scale)
        identSize = CockpitType.size(kneeboard: 28, phone: 20, scale: scale)
        frequencySize = CockpitType.size(kneeboard: 24, phone: 20, scale: scale)
        cellPadding = kneeboard ? 14 : 12
        verticalPadding = kneeboard ? 8 : 6
        rowGap = kneeboard ? 8 : 6
        figureGap = kneeboard ? 12 : 8
        cornerRadius = kneeboard ? 14 : 12
    }

    /// Between the strip and the card in the phone's column on its side, which has no point to spare.
    static let columnRowGap: CGFloat = 4
    /// The merged line's padding above and below: one line in the column's 370 pt.
    static let mergedVerticalPadding: CGFloat = 2
    /// Its padding at either end, and either side of the rule between its two halves: "ST-URSANNE" keeps
    /// the label's size beside its ETE and NOW.
    static let mergedPadding: CGFloat = 8

    /// The smallest the name scales to: the label's size.
    var identMinimumScale: CGFloat { labelSize / identSize }
    /// In the column's lines, a name wider than its room at the label's size goes on shrinking, whole:
    /// "SAIGNELÉGIER" beside NOW on a 6.1" phone, at about 14 pt. Never cut.
    static let columnNameMinimumScale: CGFloat = 0.5

    var figureFont: Font { .aero(size: figureSize, weight: .bold, design: .monospaced) }
    var identFont: Font { .aero(size: identSize, weight: .bold, design: .monospaced) }
}

/// Each figure's widest values. B612 Mono draws every character the same width, so "000.0 NM" is as wide
/// as any distance under 1000 NM; "—" is there in case it comes from another font.
enum NextFigureTemplates {
    static let bearing = ["000°", "—"]
    static let distance = ["000.0 NM", "— NM"]
    static var ete: [String] { DestinationLine.eteTemplates + ["— min"] }
    /// The ETA, the clock time alone under (beside, on the phone) the ETE: "22:58", or "10:58 PM" where
    /// the device writes it so. "ETA 22:58" was the widest figure, and on a 12-hour device "ETA 10:58 PM"
    /// left a 12-letter name under the label's size in iPad portrait.
    static var clock: [String] { [NextWaypointReadout.widestETA, "—"] }
}

// MARK: - The iPad's NEXT cell

/// The strip's fourth cell on the iPad: "NEXT" (DIVERT while diverting), the waypoint in magenta under
/// it, "E (LSGC)" where that fits and "E" where it doesn't (a static `ViewThatFits`), and its figures at
/// the right, one per line: bearing, distance, ETE, and the ETA's clock time. With no route, "—"
/// everywhere: the cell is
/// there in every phase the strip is, so the strip's cells never divide again.
struct StripNextCell: View {
    let figures: NextFigures
    var onTap: (() -> Void)? = nil
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    private var metrics: ReadBandMetrics { ReadBandMetrics(.kneeboard) }

    var body: some View {
        // A width's choice, never the figures': both arrangements are as wide as their templates and the
        // name's room whatever they show, so a cell keeps the one its width gives it all flight.
        ViewThatFits(in: .horizontal) {
            figuresBeside
            figuresUnder
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .readBandPart(.next)
    }

    /// The portrait cell's, about 315 pt wide: the name at the left, the figures one per line at the right.
    private var figuresUnder: some View {
        HStack(alignment: .top, spacing: metrics.figureGap) {
            name
            figureColumn
                .modifier(NextFiguresElement(figures: figures, onTap: onTap, language: language))
                .readBandPart(.nextFigures)
        }
    }

    /// The cell on an iPad on its side, about 655 pt wide (6.2, PR 4): the figures on one row beside the
    /// name, "206° · 17.6 NM · 10 min · 11:58" on the name's line, rather than the name far left and four
    /// lines far right. The cell keeps the portrait one's height (the figures' column, hidden), so the
    /// strip is as tall as it was.
    private var figuresBeside: some View {
        ZStack(alignment: .topLeading) {
            figureColumn.hidden().accessibilityHidden(true)
            HStack(alignment: .lastTextBaseline, spacing: Self.besideGap) {
                name
                    .frame(minWidth: Self.nameRoom, idealWidth: Self.nameRoom, maxWidth: Self.nameRoomAtMost,
                           alignment: .leading)
                figureRow
                    .modifier(NextFiguresElement(figures: figures, onTap: onTap, language: language))
                    .readBandPart(.nextFigures)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The name's least room beside the figures' row, which decides the arrangement: "SAIGNELÉGIER" at
    /// 25 pt, where the name scales before it is ever cut. The cell is about 655 pt wide on an iPad Air on
    /// its side, 315 upright: an iPad mini on its side (about 610) gets the row too.
    static let nameRoom: CGFloat = 180
    /// And its most: "SAIGNELÉGIER" whole at 28 pt, with a margin. The figures follow it, at the same
    /// place whatever the name, and a wider cell (a 13" iPad) leaves its room at the right.
    static let nameRoomAtMost: CGFloat = 240
    static let besideGap: CGFloat = 20

    private var name: some View {
        VStack(alignment: .leading, spacing: 4) {
            NextTagRow(diverting: figures.diverting, size: metrics.labelSize, language: language)
            SeparateView { NextIdent(figures: figures, metrics: metrics, language: language) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readBandPart(.nextName)
    }

    private var figureColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            figure(figures.bearingText, NextFigureTemplates.bearing)
            figure(figures.distanceText, NextFigureTemplates.distance)
            figure(figures.eteText, NextFigureTemplates.ete)
            figure(figures.etaClock, NextFigureTemplates.clock)
        }
        .fixedSize()
    }

    /// BRG · DIST · ETE · the ETA's clock time, each in its widest value's room.
    private var figureRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            figure(figures.bearingText, NextFigureTemplates.bearing)
            separator
            figure(figures.distanceText, NextFigureTemplates.distance)
            separator
            figure(figures.eteText, NextFigureTemplates.ete)
            separator
            figure(figures.etaClock, NextFigureTemplates.clock)
        }
        .fixedSize()
    }

    private var separator: some View {
        Text(verbatim: "·")
            .font(metrics.figureFont)
            .foregroundColor(theme.textSecondary)
            .accessibilityHidden(true)
    }

    private func figure(_ text: String, _ widest: [String]) -> some View {
        DestinationFigureCell(text: text, widest: widest, font: metrics.figureFont, color: theme.textPrimary)
    }
}

/// "NEXT", or the amber DIVERT tag in its place, in a row as tall as the tag whatever it shows: the name
/// under it never moves when a diversion starts.
private struct NextTagRow: View {
    let diverting: Bool
    let size: CGFloat
    var language: String?

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            tag.hidden()
            if diverting {
                tag
            } else {
                Text(verbatim: L10n.Read.nextColumn(language: language))
                    .font(.aero(size: size))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        // The name says it ("Next, E", "Diverting to LSZG").
        .accessibilityHidden(true)
    }

    private var tag: some View {
        Text(verbatim: L10n.Read.divertTag(language: language))
            .font(.aero(size: size, weight: .bold))
            .foregroundColor(theme.actionText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.warning, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The waypoint's name in magenta: the full form where it fits whole, else the plain one, which scales
/// down to the label's size before it would ever be cut. "—" with no route. Its own element, `strip.next`:
/// its label is what it shows (so a UI test finds "E (LSGC)" as text), its value the plain name ("E").
private struct NextIdent: View {
    let figures: NextFigures
    let metrics: ReadBandMetrics
    var language: String?

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            // A line's height at full size: scaled down, a long name came out 3 pt shorter.
            Text(verbatim: "0").font(metrics.identFont).hidden().accessibilityHidden(true)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let ident = figures.ident {
            ViewThatFits(in: .horizontal) {
                name(figures.fullIdent ?? ident, scales: false)
                name(ident, scales: true)
            }
        } else {
            Text(verbatim: "—")
                .font(metrics.identFont)
                .foregroundColor(theme.textSecondary)
                .accessibilityLabel(ReadBandSpeech.ident(figures, shown: "—", language: language))
                .accessibilityIdentifier("strip.next")
                .accessibilityValue("")
        }
    }

    private func name(_ shown: String, scales: Bool) -> some View {
        Text(verbatim: shown)
            .font(metrics.identFont)
            .foregroundColor(theme.route)
            .lineLimit(1)
            .minimumScaleFactor(scales ? metrics.identMinimumScale : 1)
            .fixedSize(horizontal: !scales, vertical: false)
            .accessibilityLabel(ReadBandSpeech.ident(figures, shown: shown, language: language))
            .accessibilityValue(figures.ident ?? "")
            .accessibilityIdentifier("strip.next")
    }
}

/// The figures as one element for VoiceOver, "bearing 206 degrees, 12.4 nautical miles, 7 minutes, overhead
/// at 11:58", and a button to ROUTE.
private struct NextFiguresElement: ViewModifier {
    let figures: NextFigures
    let onTap: (() -> Void)?
    var language: String?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ReadBandSpeech.figures(figures, language: language))
            .accessibilityIdentifier("read.nextFigures")
            .accessibilityAddTraits(.updatesFrequently)
            .modifier(RouteTapTraits(enabled: onTap != nil, language: language))
    }
}

/// A button to ROUTE, to VoiceOver.
private struct RouteTapTraits: ViewModifier {
    let enabled: Bool
    var language: String?

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(L10n.Read.routeHint(language: language))
        } else {
            content
        }
    }
}

// MARK: - The phone's next line

/// The phone's NEXT, under its strip of three: "NEXT" (or DIVERT) over the waypoint at the left, and its
/// figures on two rows at the right, bearing and distance, then ETE and ETA. One line of the map held the
/// name and three figures until 6.2, by shrinking them: at 17 pt they no longer fit a 12-letter name.
/// The plain name, as before ("E", never "E (LSGC)"). A tap opens ROUTE.
///
/// The Companion's NAV screen reads the same line from the iPad's stream (`NextFigures(companion:)`),
/// with the phone's turn arrow before the name: where the waypoint lies from the track.
struct ReadBandNextLine: View {
    let figures: NextFigures
    var scale: CockpitScale = .current
    /// The turn arrow, the Companion's: `.some(nil)` while the turn is unknown (no fix), dimmed; nil, no
    /// arrow (the Cockpit, whose map turns).
    var turn: Double?? = nil
    let onTap: () -> Void
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: ReadBandMetrics { ReadBandMetrics(scale) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: metrics.figureGap) {
                VStack(alignment: .leading, spacing: 2) {
                    NextTagRow(diverting: figures.diverting, size: metrics.labelSize, language: language)
                    HStack(spacing: 6) {
                        if let turn { turnArrow(turn) }
                        ZStack(alignment: .leading) {
                            // A line's height at full size, whatever a long name scales to.
                            Text(verbatim: "0").font(metrics.identFont).hidden()
                            Text(verbatim: figures.ident ?? "—")
                                .font(metrics.identFont)
                                .foregroundColor(figures.ident == nil ? theme.textSecondary : theme.route)
                                .lineLimit(1)
                                .minimumScaleFactor(metrics.identMinimumScale)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: metrics.figureGap) {
                        figure(figures.bearingText, NextFigureTemplates.bearing)
                        figure(figures.distanceText, NextFigureTemplates.distance)
                    }
                    HStack(spacing: metrics.figureGap) {
                        figure(figures.eteText, NextFigureTemplates.ete)
                        figure(figures.etaClock, NextFigureTemplates.clock)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, metrics.cellPadding)
            .padding(.vertical, metrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ReadBandSpeech.nextLine(figures, language: language))
        .accessibilityAddTraits([.isButton, .updatesFrequently])
        .accessibilityHint(L10n.Read.routeHint(language: language))
        .accessibilityIdentifier("read.nextLine")
        .readBandPart(.nextLine)
    }

    private func figure(_ text: String, _ widest: [String]) -> some View {
        DestinationFigureCell(text: text, widest: widest, font: metrics.figureFont, color: theme.textPrimary)
    }

    /// The arrow turns inside its square, nothing beside it moves; amber while diverting, dimmed with no
    /// turn to show, gone with no leg.
    private func turnArrow(_ degrees: Double?) -> some View {
        Image(systemName: "arrow.up")
            .font(.aero(size: metrics.labelSize, weight: .bold))
            .foregroundColor(figures.diverting ? theme.warning : theme.route)
            .rotationEffect(.degrees(degrees ?? 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: degrees ?? 0)
            .frame(width: Self.arrowSize, height: Self.arrowSize)
            .opacity(degrees == nil ? 0.35 : 1)
            .opacity(figures.ident == nil ? 0 : 1)
    }

    static let arrowSize: CGFloat = 24
}

// MARK: - The phone's column on its side (6.2, PR 5)

/// The next waypoint on one line, in the phone's column on its side (a Pro Max, 400 pt tall or more): the
/// name in magenta at the left, its distance · its ETE at the right, each in its widest value's room.
/// The bearing and the ETA are on ROUTE. A tap opens ROUTE. "SAIGNELÉGIER" holds whole at 17 pt.
struct ReadBandColumnNextLine: View {
    let figures: NextFigures
    var scale: CockpitScale = .current
    let onTap: () -> Void
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    private var metrics: ReadBandMetrics { ReadBandMetrics(scale) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.figureGap) {
                ReadBandColumnName(figures: figures, metrics: metrics)
                // A dot between the two, as the iPad's row has them: side by side, "17.5 NM 10 min" read as
                // "NM 10".
                HStack(alignment: .firstTextBaseline, spacing: Self.dotGap) {
                    figure(figures.distanceText, NextFigureTemplates.distance)
                    Text(verbatim: "·")
                        .font(metrics.figureFont)
                        .foregroundColor(theme.textSecondary)
                        .accessibilityHidden(true)
                    figure(figures.eteText, NextFigureTemplates.ete)
                }
                .fixedSize()
            }
            .padding(.horizontal, metrics.cellPadding)
            .padding(.vertical, metrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(NextLineElement(figures: figures, language: language))
        .readBandPart(.nextLine)
    }

    private func figure(_ text: String, _ widest: [String]) -> some View {
        DestinationFigureCell(text: text, widest: widest, font: metrics.figureFont, color: theme.textPrimary)
    }

    static let dotGap: CGFloat = 6
}

/// The next line and the NOW line as one, in the phone's column on its side under 400 pt tall: the
/// waypoint in magenta and its ETE, then NOW and its frequency. The distance, the bearing, the ETA and NOW's
/// station are on ROUTE, where a tap on either half goes. Every figure in its widest value's room and NOW's
/// half as wide whatever it shows, so the name keeps one room: "ST-URSANNE" at 17 pt, a longer name smaller,
/// whole. `figures` nil: NOW alone (a phase without the strip).
struct ReadBandMergedLine: View {
    let figures: NextFigures?
    let now: PhaseFrequency?
    /// NEXT, due: in NOW's half in its place, "› 120.105", outlined, and the half's tap switches to it. The line
    /// has no room for both frequencies, nor for a wider tag. (6.4.3)
    var dueNext: PhaseFrequency? = nil
    var scale: CockpitScale = .current
    let onTap: () -> Void
    /// NOW's half: ROUTE on RADIO; nil, `onTap`. (6.2.0)
    var onNowTap: (() -> Void)? = nil
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    private var metrics: ReadBandMetrics { ReadBandMetrics(scale) }

    var body: some View {
        HStack(spacing: 0) {
            if let figures {
                Button(action: onTap) {
                    HStack(alignment: .firstTextBaseline, spacing: metrics.figureGap) {
                        ReadBandColumnName(figures: figures, metrics: metrics)
                        DestinationFigureCell(text: figures.eteText, widest: NextFigureTemplates.ete,
                                              font: metrics.figureFont, color: theme.textPrimary)
                    }
                    .padding(.leading, ReadBandMetrics.mergedPadding)
                    .padding(.trailing, ReadBandMetrics.mergedPadding)
                    .padding(.vertical, ReadBandMetrics.mergedVerticalPadding)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(NextLineElement(figures: figures, language: language))
                .readBandPart(.nextLine)
                Rectangle().fill(theme.glassStroke).frame(width: 0.5)
                    .padding(.vertical, metrics.verticalPadding)
            }
            nowHalf
                .frame(maxWidth: figures == nil ? .infinity : nil, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// NOW and the frequency to dial, in the room of the widest it can show; NEXT in its place while due.
    private var nowHalf: some View {
        let shown = ReadBandFrequencyText(dueNext ?? now)
        let title = L10n.Read.now(language: language)
        return Button(action: onNowTap ?? onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                ZStack(alignment: .leading) {
                    // NOW's room: the frequency stays put when NEXT comes due, the name beside keeps its room.
                    tag(title).foregroundColor(theme.onTarget).opacity(dueNext == nil ? 1 : 0)
                    if dueNext != nil {
                        Text(verbatim: "›")
                            .font(metrics.figureFont)
                            .foregroundColor(theme.info)
                    }
                }
                DestinationFigureCell(text: shown.frequency, widest: ReadBandMergedLine.frequencyTemplates,
                                      font: metrics.figureFont, color: theme.textPrimary)
            }
            .padding(.horizontal, ReadBandMetrics.mergedPadding)
            .padding(.vertical, ReadBandMetrics.mergedVerticalPadding)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay { if let dueNext { ReadBandDueCue(left: dueNext.dueLeft, cornerRadius: metrics.cornerRadius) } }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dueNext.map { ReadBandSpeech.due(now: now, next: $0, language: language) }
                            ?? ReadBandSpeech.frequency(title: title, item: now))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(dueNext == nil ? L10n.Read.routeHint(language: language) : L10n.Read.switchHint(language: language))
        .accessibilityIdentifier("read.now")
        .readBandPart(.nowLine)
    }

    /// A frequency at its widest, "121.500" as "000.000", and none.
    static let frequencyTemplates = ["000.000", "—"]

    private func tag(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.aero(size: metrics.labelSize, weight: .bold))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The waypoint's name in the column's lines: in magenta, at the name's size where it fits, down to the
/// label's, then smaller where the word alone is wider than its room, whole, never cut. While diverting,
/// framed in amber (the line has no room for the DIVERT tag, and a tag coming would move the figures).
private struct ReadBandColumnName: View {
    let figures: NextFigures
    let metrics: ReadBandMetrics

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            // A line's height at full size, whatever a long name scales to.
            Text(verbatim: "0").font(metrics.identFont).hidden()
            Text(verbatim: figures.ident ?? "—")
                .font(metrics.identFont)
                .foregroundColor(figures.ident == nil ? theme.textSecondary : theme.route)
                .lineLimit(1)
                .minimumScaleFactor(ReadBandMetrics.columnNameMinimumScale)
                .padding(.horizontal, figures.diverting ? 4 : 0)
                .overlay {
                    if figures.diverting {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(theme.warning, lineWidth: 2)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readBandPart(.nextName)
    }
}

/// The column's next line as one element: what the portrait's next line reads ("Next, E, bearing 172
/// degrees, …", the replays' `read.nextLine`), and a button to ROUTE.
private struct NextLineElement: ViewModifier {
    let figures: NextFigures
    var language: String?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ReadBandSpeech.nextLine(figures, language: language))
            .accessibilityAddTraits([.isButton, .updatesFrequently])
            .accessibilityHint(L10n.Read.routeHint(language: language))
            .accessibilityIdentifier("read.nextLine")
    }
}

// MARK: - NOW | NEXT

/// The iPad's two frequencies under the strip, on every page: NOW, the station to talk to, and NEXT, the
/// one to call next (`CockpitRadio`), each on one line. A tap on either opens ROUTE, where every
/// frequency is.
struct ReadBandFrequencies: View {
    let now: PhaseFrequency?
    let next: PhaseFrequency?
    var scale: CockpitScale = .current
    let onTap: () -> Void
    /// NOW: ROUTE › RADIO; nil, `onTap`. (6.4.3, q4)
    var onNowTap: (() -> Void)? = nil
    /// NEXT: the switch; nil, `onTap`. (6.4.3)
    var onNextTap: (() -> Void)? = nil
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    private var metrics: ReadBandMetrics { ReadBandMetrics(scale) }

    var body: some View {
        HStack(spacing: 0) {
            ReadBandFrequencyCell(role: .now, item: now, scale: scale, onTap: onNowTap ?? onTap, language: language)
                .readBandPart(.now)
            Rectangle().fill(theme.glassStroke).frame(width: 0.5)
                .padding(.vertical, metrics.verticalPadding)
            ReadBandFrequencyCell(role: .next, item: next, scale: scale, onTap: onNextTap ?? onTap,
                                  switches: onNextTap != nil, language: language)
                .readBandPart(.nextFrequency)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.glassFill, in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius).strokeBorder(theme.glassStroke, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("read.frequencies")
        .readBandPart(.frequencies)
    }
}

/// The phone's NOW, the line under its next line.
struct ReadBandNowLine: View {
    let now: PhaseFrequency?
    /// NEXT, due, beside NOW: "NOW 124.700 › 120.105 LSZG TWR HX", and the tap switches. (6.4.3, q8)
    var dueNext: PhaseFrequency? = nil
    var scale: CockpitScale = .current
    let onTap: () -> Void
    var language: String? = nil

    var body: some View {
        ReadBandFrequencyCell(role: .now, item: now, dueNext: dueNext, scale: scale, onTap: onTap,
                              switches: dueNext != nil, alignsTags: false, language: language)
            .readBandPart(.nowLine)
    }
}

/// NOW or NEXT on one line: the tag, the frequency, then the station where it fits whole. The frequency is
/// what is dialled: it comes first and keeps its digits; the station gives way, down to three quarters of its
/// size, never to nothing ("NOW 120.105" alone confused the author, device check zn-3, 6.4.2). What a pilot typed for a waypoint ("119.175 Bern Information") is read as its frequency and its
/// words (`ReadBandFrequencyText`), the words in the station's place. The tag's room is the wider of the
/// two tags, so NOW's frequency and NEXT's line up.
struct ReadBandFrequencyCell: View {
    enum Role { case now, next }

    let role: Role
    let item: PhaseFrequency?
    /// NOW's line on the phone: NEXT, due, after NOW's frequency, and its station in NOW's. (6.4.3)
    var dueNext: PhaseFrequency? = nil
    var scale: CockpitScale = .current
    let onTap: () -> Void
    /// The tap switches (or marks a LISTEN heard) rather than open ROUTE: what VoiceOver says it does. (6.4.3)
    var switches = false
    /// The tag in the room of the widest of the three, so NOW's and NEXT's frequencies line up on the iPad. The
    /// phone's NOW line, NOW's tag alone, gives that room to the station of a due NEXT beside it. (6.4.3)
    var alignsTags = true
    var language: String? = nil

    @Environment(\.cockpitTheme) private var theme

    private var metrics: ReadBandMetrics { ReadBandMetrics(scale) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.figureGap) {
                ZStack(alignment: .leading) {
                    // The widest of the three tags, whichever shows: NOW's and NEXT's frequencies line up and
                    // never move when LISTEN comes. (6.4.2)
                    if alignsTags {
                        tagText(L10n.Read.now(language: language)).hidden()
                        tagText(L10n.Read.next(language: language)).hidden()
                        tagText(L10n.Read.listen(language: language)).hidden()
                    }
                    tagText(title).foregroundColor(tint)
                }
                .accessibilityHidden(true)
                // NOW's frequency stays where it is when a due NEXT comes beside it, smaller and in grey: the one
                // to leave, and the room the due station needs to show whole on a phone.
                FrequencyLineText(text: shown.frequency,
                                  font: dueNext == nil ? frequencyFont
                                      : .aero(size: metrics.labelSize, weight: .regular, design: .monospaced),
                                  color: dueNext == nil ? theme.textPrimary : theme.textSecondary)
                    .layoutPriority(1)
                if let dueNext {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "›")
                            .font(.aero(size: metrics.frequencySize, weight: .bold))
                            .foregroundColor(theme.info)
                            .accessibilityHidden(true)
                        FrequencyLineText(text: ReadBandFrequencyText(dueNext).frequency, font: frequencyFont,
                                          color: theme.textPrimary)
                    }
                    .layoutPriority(1)
                }
                station(of: dueNext ?? item)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, metrics.cellPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay { if let due { ReadBandDueCue(left: due.dueLeft, cornerRadius: metrics.cornerRadius) } }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hint)
        .accessibilityIdentifier(role == .now ? "read.now" : "read.next")
    }

    /// The due call this cell shows: NEXT's own, or the one beside NOW on the phone.
    private var due: PhaseFrequency? {
        role == .now ? dueNext : (item?.due == true ? item : nil)
    }

    private var frequencyFont: Font { .aero(size: metrics.frequencySize, weight: .bold, design: .monospaced) }

    /// The station after the frequency where it fits whole: with a TMA the FIS clears beside it, alone, then
    /// down to three quarters of its size. (6.4.2)
    private func station(of item: PhaseFrequency?) -> some View {
        let shown = ReadBandFrequencyText(item)
        return ViewThatFits(in: .horizontal) {
            if let note = item?.note {
                stationText(shown.station + " · " + note)
            }
            stationText(shown.station)
            Text(verbatim: shown.station)
                .font(.aero(size: metrics.labelSize))
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var label: String {
        if let dueNext { return ReadBandSpeech.due(now: item, next: dueNext, language: language) }
        let read = ReadBandSpeech.frequency(title: title, item: item)
        return item?.due == true ? read + ", " + L10n.Read.due(language: language) : read
    }

    private var hint: String {
        guard switches else { return L10n.Read.routeHint(language: language) }
        return item?.listen == true && role == .next ? L10n.Read.heardHint(language: language)
            : L10n.Read.switchHint(language: language)
    }

    private var title: String {
        if role == .now { return L10n.Read.now(language: language) }
        return item?.listen == true ? L10n.Read.listen(language: language) : L10n.Read.next(language: language)
    }

    private func stationText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.aero(size: metrics.labelSize))
            .foregroundColor(theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var shown: ReadBandFrequencyText { ReadBandFrequencyText(item) }

    private var tint: Color { role == .now ? theme.onTarget : theme.info }

    private func tagText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.aero(size: metrics.labelSize, weight: .bold))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A due NEXT (6.4.3, the author's q3 B): an outline in NEXT's colour, and a line along its foot that runs out
/// where the app switches by itself (`left`, 1 to 0; none when it won't). Over the cell, so nothing moves.
struct ReadBandDueCue: View {
    let left: Double?
    let cornerRadius: CGFloat

    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(theme.info, lineWidth: 2)
            .overlay(alignment: .bottom) {
                if let left {
                    Capsule().fill(theme.glassStroke)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.info)
                                .scaleEffect(x: max(0, min(1, left)), anchor: .leading)
                                // A fix a second: the line runs out smoothly between them, as UNDO's does; with
                                // Reduce Motion it steps once a second, as UNDO's does then. (6.4.3)
                                .animation(reduceMotion ? nil : .linear(duration: 1), value: left)
                        }
                        .frame(height: 3)
                        // Clear of the outline's rounded corners.
                        .padding(.horizontal, max(8, cornerRadius * 0.75))
                        .padding(.bottom, 5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A frequency as the band shows it: the number to dial, and the words beside it. A field's or an area's
/// is its frequency and its station ("118.125", "LSGC TWR"). What a pilot typed for a waypoint is split:
/// "119.175 Bern Information" is "119.175" and "Bern Information" (the words in the station's place, where
/// the waypoint's name was), and of several ("Info 124.705 / Tower 118.125") the first, as NOW and NEXT are
/// one station each; ROUTE lists them all. Text with no frequency in it is shown as typed. Pure. (6.2)
struct ReadBandFrequencyText: Equatable {
    let frequency: String
    let station: String

    init(frequency: String, station: String) {
        self.frequency = frequency
        self.station = station
    }

    init(_ item: PhaseFrequency?) {
        guard let item else {
            self.init(frequency: "—", station: "")
            return
        }
        let first = FrequencyRow.parts(of: item.freq).first ?? item.freq
        guard let range = first.range(of: #"[0-9]{3}[.,][0-9]{1,3}"#, options: .regularExpression) else {
            self.init(frequency: item.freq, station: item.station)
            return
        }
        let words = (first[..<range.lowerBound] + " " + first[range.upperBound...])
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.init(frequency: String(first[range]), station: words.isEmpty ? item.station : words)
    }
}

// MARK: - What VoiceOver reads

/// The band in words. Figures as the band rounds them, spelt out by Foundation in the band's language,
/// so VoiceOver never reads "N M" or "min".
enum ReadBandSpeech {
    /// The NEXT cell's name: "Next, E (LSGC)", "Diverting to LSZG", "Next, no waypoint ahead".
    static func ident(_ figures: NextFigures, shown: String, language: String?) -> String {
        guard figures.ident != nil else {
            return L10n.Read.nextWaypoint(language: language) + ", " + L10n.Read.noTarget(language: language)
        }
        if figures.diverting { return L10n.Dest.divertingTo(shown, language: language) }
        return L10n.Read.nextWaypoint(language: language) + ", " + shown
    }

    /// "bearing 206 degrees, 12.4 nautical miles, 7 minutes, overhead at 11:58"; the parts there are.
    static func figures(_ figures: NextFigures, language: String?) -> String {
        var parts: [String] = []
        if let bearing = figures.bearing {
            parts.append(L10n.Read.bearing(Int(bearing), language: language))
        }
        if let distance = figures.distanceNM {
            parts.append(Self.distance(distance, language: language))
        }
        if let live = figures.live {
            parts.append(DestinationSpeech.duration(minutes: (live.ete / 60).safeRoundedInt(or: 0), language: language))
            parts.append(L10n.Dest.overhead(DestinationFormat.clock(live.eta), language: language))
        }
        return parts.joined(separator: ", ")
    }

    /// The phone's next line: the name as its own part ("Next, E, bearing 172 degrees, …"), which the
    /// replays read.
    static func nextLine(_ figures: NextFigures, language: String?) -> String {
        let name: String
        if let ident = figures.ident {
            name = (figures.diverting ? L10n.Read.divertTag(language: language) : L10n.Read.nextWaypoint(language: language))
                + ", " + ident
        } else {
            name = L10n.Read.nextWaypoint(language: language) + ", " + L10n.Read.noTarget(language: language)
        }
        let rest = Self.figures(figures, language: language)
        return rest.isEmpty ? name : name + ", " + rest
    }

    /// "NOW, 120.375, LSZQ AFIS".
    static func frequency(title: String, item: PhaseFrequency?) -> String {
        guard let item else { return title + ", —" }
        return [title, item.freq, item.station].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The phone's NOW line with NEXT due beside it: "NOW, 124.700, Zürich Info, NEXT, 120.105, LSZG TWR HX,
    /// due". (6.4.3)
    static func due(now: PhaseFrequency?, next: PhaseFrequency, language: String?) -> String {
        [frequency(title: L10n.Read.now(language: language), item: now),
         frequency(title: L10n.Read.next(language: language), item: next),
         L10n.Read.due(language: language)].joined(separator: ", ")
    }

    /// "12.4 nautical miles", "12,4 milles marins": to the tenth, as the band writes it.
    static func distance(_ nauticalMiles: Double, language: String?) -> String {
        let shown = Double(NextWaypointReadout.distance(nauticalMiles)) ?? nauticalMiles
        let formatter = MeasurementFormatter()
        formatter.locale = Locale(identifier: language ?? Bundle.main.preferredLocalizations.first ?? "en")
        formatter.unitStyle = .long
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: Measurement(value: shown, unit: UnitLength.nauticalMiles))
    }
}

// MARK: - The tests' layout hook

/// A part of the read band, for the layout tests.
enum ReadBandPart: Hashable {
    case rows, strip, speed, altitude, track, next, nextName, nextFigures, frequencies, now, nextFrequency,
         nextLine, nowLine
}

private struct ReadBandReporterKey: EnvironmentKey {
    static let defaultValue: ((ReadBandPart, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    /// The read band's layout hook, the tests' only.
    var readBandReporter: ((ReadBandPart, CGRect) -> Void)? {
        get { self[ReadBandReporterKey.self] }
        set { self[ReadBandReporterKey.self] = newValue }
    }
}

/// Reports a part's frame in the band's space, when a test asks: nothing at all otherwise.
private struct ReadBandPartReader: ViewModifier {
    let part: ReadBandPart
    @Environment(\.readBandReporter) private var report

    func body(content: Content) -> some View {
        if let report {
            content.background(GeometryReader { proxy in
                let _ = report(part, proxy.frame(in: .named(CockpitReadRows.space)))
                Color.clear
            })
        } else {
            content
        }
    }
}

extension View {
    func readBandPart(_ part: ReadBandPart) -> some View {
        modifier(ReadBandPartReader(part: part))
    }
}

// MARK: - Previews

#if DEBUG
/// The band's states, for the previews and the tests: the proposal's route, 17.6 NM from LSGC at 104 kt.
enum ReadBandSample {
    static let strip = StripReading(speedKnots: 104, targetSpeed: 100, gpsSignalStatus: .good, altitudeFeet: 4_500,
                                    headingDegrees: 211, verticalSpeedFPM: nil)

    static func next(ident: String? = "LSGC", full: String? = nil, diverting: Bool = false,
                     bearing: Double? = 206, distance: Double? = 17.6, gs: Double = 104,
                     now: Date = DestinationLineSample.at(11, 17, 20)) -> NextFigures {
        guard ident != nil else { return .none }
        return NextFigures(ident: ident, fullIdent: full, diverting: diverting, bearing: bearing, distanceNM: distance,
                           live: NextLegLive(distanceNM: distance, groundSpeedKnots: gs, now: now))
    }

    static let nowField = PhaseFrequency(station: "LSZQ AFIS", freq: "120.375", highlighted: true, isEmergency: false,
                                         role: .current)
    static let nextField = PhaseFrequency(station: "LSGC TWR", freq: "118.125", highlighted: true, isEmergency: false,
                                          role: .next)
    /// What a pilot typed for a waypoint.
    static let typed = PhaseFrequency(station: "SAIGNELÉGIER", freq: "119.175 Bern Information", highlighted: true,
                                      isEmergency: false, role: .current)
    /// NEXT due, its line a third gone; and due with no line (the app's switch undone). (6.4.3)
    static let due = PhaseFrequency(station: "LSZG TWR HX", freq: "120.105", highlighted: true, isEmergency: false,
                                    role: .next, due: true, dueLeft: 0.65)
    static let dueNoLine = PhaseFrequency(station: "LSZG TWR HX", freq: "120.105", highlighted: true, isEmergency: false,
                                          role: .next, due: true)

    /// Every state the band must hold still through, with its name.
    static var states: [(name: String, strip: StripReading, next: NextFigures, now: PhaseFrequency?, nextFrequency: PhaseFrequency?)] {
        var lost = strip
        lost.gpsSignalStatus = .lost
        var climbing = strip
        climbing.verticalSpeedFPM = 650
        return [
            ("route", strip, next(), nowField, nextField),
            ("no route", strip, .none, nil, nil),
            ("diverting", strip, next(ident: "LSZG", diverting: true, bearing: 74, distance: 12.4), nowField, nextField),
            ("no fix", strip, next(bearing: nil, distance: nil), nowField, nextField),
            ("GPS lost", lost, next(), nowField, nextField),
            ("9.9 NM", climbing, next(distance: 9.9), nowField, nextField),
            ("10.0 NM", strip, next(distance: 10.0), nowField, nextField),
            ("59 min", strip, next(distance: 102.2), nowField, nextField),
            ("60 min", strip, next(distance: 104), nowField, nextField),
            ("below 30 kt", strip, next(gs: 12), nowField, nextField),
            ("E (LSGC)", strip, next(ident: "E", full: "E (LSGC)"), nowField, nextField),
            ("SAIGNELÉGIER", strip, next(ident: "SAIGNELÉGIER"), nowField, nextField),
            ("diverting to SAIGNELÉGIER", strip, next(ident: "SAIGNELÉGIER", diverting: true, distance: 105), nowField, nextField),
            ("NOW typed", strip, next(), typed, nextField),
            ("NEXT due", strip, next(), nowField, due),
            ("NEXT due, no line", strip, next(), nowField, dueNoLine),
            ("NOW typed, NEXT due", strip, next(ident: "SAIGNELÉGIER"), typed, due),
        ]
    }
}

private struct ReadBandPreview: View {
    let layout: CockpitLayout
    var language: String? = nil

    var body: some View {
        let scale: CockpitScale = layout == .wide ? .kneeboard : .phone
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ReadBandSample.states, id: \.name) { state in
                    Text(verbatim: state.name).font(.caption).foregroundColor(.gray).padding(.horizontal)
                    CockpitReadRows(layout: layout, scale: scale, strip: state.strip, next: state.next, now: state.now,
                                    nextFrequency: state.nextFrequency, onShowRoute: {}, onNextTap: {},
                                    language: language)
                }
            }
            .padding(.vertical, 16)
        }
        .frame(width: layout == .wide ? 820 : 402)
        .background(CockpitTheme.day.background)
    }
}

#Preview("iPad") { ReadBandPreview(layout: .wide) }
#Preview("iPad, French") { ReadBandPreview(layout: .wide, language: "fr") }
#Preview("Phone") { ReadBandPreview(layout: .narrow) }
#Preview("Phone, French") { ReadBandPreview(layout: .narrow, language: "fr") }
#endif
