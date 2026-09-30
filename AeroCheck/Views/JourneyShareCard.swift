import SwiftUI
import UIKit

// MARK: - Journey Share Card

/// One image for several flights: a day of the Logbook or a trip's legs (6.1, proposal of 29 Sep,
/// part 3, J1, approved as recommended). The date, the aircraft, the route chain ("LSZQ → LSGE →
/// LSGN → LSZQ") and the aerodromes' names; flight time, block time, distance and landings summed per
/// leg; one map with every leg numbered and the day's aerodromes; the legs with their times and each
/// stop's time on the ground; the day's timeline of air and ground; the profile of the legs in the
/// air, joined by the stops.
///
/// It is the single card's family: the same themes, formats, top bar, tiles, map renderer, profile
/// and footer (`FlightShareCard`), and in the Full map style the single card's own band and panel.
/// Every figure comes from `ShareCardJourney`. Fixed fonts by design, as the single card.
struct JourneyShareCard: View {
    let journey: ShareCardJourney
    let mapImage: UIImage?
    var colorScheme: ShareCardColorScheme = .darkBlue
    /// Each leg's terrain, by flight: empty without the TERRAIN switch.
    var terrain: [UUID: [(time: Date, elevationFeet: Double)]] = [:]
    var mapPlaceholder: ShareCardMapPlaceholder = .noTrack
    var credit: String?
    var style: ShareCardStyle = .standard
    var format: ShareCardFormat = .story
    /// The aerodromes' names by ident, for the line under the chain.
    var names: [String: String] = [:]

    /// The magenta of a route, as the track on the chart.
    static let routeColor = Color(red: 0.9, green: 0.0, blue: 0.6)

    // MARK: Layout

    var layout: ShareCardJourneyLayout { .make(for: journey, format: format) }

    /// The Full map style's band and panel: the single card's own.
    private var fullMapLayout: ShareCardLayout {
        ShareCardLayout(style: .fullMap, format: format, hasRouteStrip: false, hasCounts: false)
    }

    /// What the sheet asks the renderer for: the map's frame on the card for the style and the
    /// format, the share of it kept clear by the Full map's fades, and how the tracks are drawn.
    static func mapShape(for journey: ShareCardJourney, style: ShareCardStyle,
                         format: ShareCardFormat) -> (frame: CGSize, clearTop: CGFloat, clearBottom: CGFloat, style: ShareCardMapStyle) {
        switch style {
        case .standard:
            return (ShareCardJourneyLayout.make(for: journey, format: format).mapFrame, 0, 0, .standard)
        case .fullMap:
            let layout = ShareCardLayout(style: .fullMap, format: format, hasRouteStrip: false, hasCounts: false)
            return (layout.mapFrame, layout.mapClearTop, layout.mapClearBottom, layout.mapStyle)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            colorScheme.backgroundColor
            switch style {
            case .standard: standardCard
            case .fullMap: fullMapCard
            }
        }
        .frame(width: format.size.width, height: format.size.height)
        .clipped()
    }

    // MARK: Standard (J1)

    private var standardCard: some View {
        let layout = self.layout
        let map = layout.mapFrame
        return VStack(spacing: 0) {
            topBar
                .frame(height: layout.topBarHeight)
                .padding(.top, layout.topPadding)
                .padding(.horizontal, layout.textMargin)

            titleBlock(chainFont: layout.chainFont, subtitleFont: layout.subtitleFont,
                       width: layout.canvas.width - 2 * layout.textMargin)
                .frame(height: layout.titleBlockHeight, alignment: .topLeading)
                .padding(.top, layout.titleGap)
                .padding(.horizontal, layout.textMargin)

            HStack(spacing: 12) {
                tile("clock", journey.flightTime, L10n.ShareCard.flightTime, layout)
                tile("timer", journey.blockTime, L10n.ShareCard.blockTime, layout)
                tile("point.topleft.down.to.point.bottomright.curvepath.fill", journey.distance,
                     L10n.ShareCard.distance, layout)
                tile("airplane.arrival", "\(journey.landings)", L10n.ShareCard.landings(journey.landings), layout)
            }
            .frame(height: layout.tileHeight)
            .padding(.top, layout.tilesGap)
            .padding(.horizontal, layout.boxMargin)

            Group {
                switch layout.arrangement {
                case .beside:
                    HStack(alignment: .top, spacing: layout.listGap) {
                        ShareCardMapBox(image: mapImage, placeholder: mapPlaceholder, size: map, cornerRadius: 24,
                                        scheme: colorScheme)
                        JourneyLegList(journey: journey, layout: layout, height: map.height, scheme: colorScheme,
                                       timeNote: journey.timeline == nil ? journey.timeNote : nil)
                            .frame(width: layout.listWidth, height: map.height, alignment: .top)
                    }
                case .under:
                    VStack(spacing: layout.gridGap) {
                        ShareCardMapBox(image: mapImage, placeholder: mapPlaceholder, size: map, cornerRadius: 24,
                                        scheme: colorScheme)
                        JourneyLegGrid(journey: journey, layout: layout, scheme: colorScheme,
                                       timeNote: journey.timeline == nil ? journey.timeNote : nil)
                            .frame(height: layout.gridHeight, alignment: .top)
                    }
                }
            }
            .padding(.top, layout.mapGap)
            .padding(.horizontal, layout.boxMargin)

            if let timeline = journey.timeline {
                sectionHeader(journey.spansDays ? L10n.ShareCard.theTrip : L10n.ShareCard.theDay,
                              trailing: journey.timeNote.uppercased(with: journey.locale))
                    .frame(height: layout.sectionHeaderHeight)
                    .padding(.top, layout.sectionGap)
                    .padding(.horizontal, layout.textMargin)
                JourneyTimeline(journey: journey, timeline: timeline, scheme: colorScheme,
                                isStory: format == .story)
                    .frame(height: layout.timelineHeight)
                    .padding(.top, layout.sectionHeaderGap)
                    .padding(.horizontal, layout.boxMargin)
            }

            sectionHeader(L10n.ShareCard.altitudeInTheAir,
                          trailing: journey.maxAltitude.map(L10n.ShareCard.peak))
                .frame(height: layout.sectionHeaderHeight)
                .padding(.top, layout.sectionGap)
                .padding(.horizontal, layout.textMargin)
            profile(axis: true, labelSize: format == .story ? 13 : 12, axisSize: format == .story ? 15 : 13,
                    gapWidth: format == .story ? 86 : 64)
                .frame(height: layout.profileHeight)
                .background(RoundedRectangle(cornerRadius: 14).fill(colorScheme.cardOverlayColor.opacity(0.6)))
                .padding(.top, layout.sectionHeaderGap)
                .padding(.horizontal, layout.boxMargin)

            Spacer(minLength: 0)

            ShareCardFooter(credit: credit, scheme: colorScheme)
                .frame(height: layout.footerHeight, alignment: .bottom)
                .padding(.horizontal, layout.textMargin)
                .padding(.bottom, layout.bottomPadding)
        }
    }

    private func tile(_ icon: String, _ value: String, _ label: String, _ layout: ShareCardJourneyLayout) -> some View {
        ShareCardTile(icon: icon, value: value, label: label, format: format, valueFont: layout.tileValueFont,
                      scheme: colorScheme)
    }

    // MARK: Full map

    private var fullMapCard: some View {
        let layout = fullMapLayout
        let band = layout.mapFrame
        let valueSize: CGFloat = format == .story ? 32 : 28
        return ZStack(alignment: .top) {
            ShareCardMapBox(image: mapImage, placeholder: mapPlaceholder, size: band, cornerRadius: 0,
                            scheme: colorScheme)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [colorScheme.backgroundColor, colorScheme.backgroundColor.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: layout.fadeTop)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [colorScheme.backgroundColor.opacity(0), colorScheme.backgroundColor],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: layout.fadeBottom)
                }
                .padding(.top, layout.bandTop)

            VStack(spacing: 0) {
                topBar
                    .frame(height: layout.topBarHeight)
                    .padding(.top, layout.topPadding)
                    .padding(.horizontal, layout.textMargin)
                titleBlock(chainFont: layout.titleFont, subtitleFont: layout.subtitleFont,
                           width: layout.canvas.width - 2 * layout.textMargin)
                    .frame(height: layout.titleBlockHeight, alignment: .topLeading)
                    .padding(.top, layout.titleGap)
                    .padding(.horizontal, layout.textMargin)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: layout.panelSpacing) {
                    HStack(alignment: .top, spacing: 8) {
                        ShareCardPanelFigure(value: journey.flightTime, label: L10n.ShareCard.flightTime,
                                             size: valueSize, scheme: colorScheme)
                        ShareCardPanelFigure(value: journey.blockTime, label: L10n.ShareCard.blockTime,
                                             size: valueSize, scheme: colorScheme)
                        ShareCardPanelFigure(value: journey.distance, label: L10n.ShareCard.distance,
                                             size: valueSize, scheme: colorScheme)
                        ShareCardPanelFigure(value: "\(journey.landings)",
                                             label: L10n.ShareCard.landings(journey.landings),
                                             size: valueSize, scheme: colorScheme)
                    }
                    .frame(height: layout.panelFiguresHeight, alignment: .top)
                    profile(axis: false, labelSize: 12, axisSize: 13, gapWidth: 64)
                        .frame(height: layout.panelProfileHeight)
                    ShareCardFooter(credit: credit, scheme: colorScheme)
                        .frame(height: layout.footerHeight, alignment: .bottom)
                }
                .padding(.horizontal, layout.panelPadding + 6)
                .padding(.vertical, layout.panelPadding)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(colorScheme.primaryTextColor.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(colorScheme.primaryTextColor.opacity(0.07), lineWidth: 1))
                )
                .frame(height: layout.panelHeight)
                .padding(.horizontal, layout.panelMargin)
                .padding(.bottom, layout.panelMargin)
            }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        ShareCardTopBar(date: journey.dateText, model: journey.aircraftModel, registration: journey.badge,
                        scheme: colorScheme)
    }

    /// The chain, folded in the middle when it would not fit at 70 % of its size, over "3 legs ·
    /// Bressaucourt · Ecuvillens · Neuchâtel".
    private func titleBlock(chainFont: CGFloat, subtitleFont: CGFloat, width: CGFloat) -> some View {
        let measure = UIFont(name: AeroTypeface.bold, size: chainFont * 0.7) ?? .boldSystemFont(ofSize: chainFont * 0.7)
        let chain = journey.chainText { text in
            (text as NSString).size(withAttributes: [.font: measure]).width <= width
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: chain)
                .font(.aero(size: chainFont, weight: .bold))
                .foregroundColor(colorScheme.primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(verbatim: journey.subtitle { names[$0] })
                .font(.aero(size: subtitleFont))
                .foregroundColor(colorScheme.secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title)
                .font(.aero(size: 14, weight: .bold))
                .foregroundColor(colorScheme.tertiaryTextColor)
                .tracking(2)
                .lineLimit(1)
            Spacer(minLength: 16)
            if let trailing {
                Text(trailing)
                    .font(.aero(size: 14, weight: .bold))
                    .foregroundColor(colorScheme.sparklineColor.opacity(0.85))
                    .tracking(1)
                    .lineLimit(1)
            }
        }
    }

    /// The legs in the air on one scale, the stops between them.
    private func profile(axis: Bool, labelSize: CGFloat, axisSize: CGFloat, gapWidth: CGFloat) -> some View {
        let figures = journey.legs.first.map(journey.figures)
        let segments = journey.profileSegments.map { segment -> ShareCardProfile.Segment in
            let id = journey.legs[segment.leg - 1].id
            func mark(_ date: Date?) -> ShareCardProfile.Mark? {
                guard axis, let date, let figures else { return nil }
                return ShareCardProfile.Mark(time: date, label: figures.time(date))
            }
            return ShareCardProfile.Segment(track: segment.track, terrain: terrain[id] ?? [],
                                            takeoff: mark(segment.takeoff), landing: mark(segment.landing))
        }
        return ShareCardProfile(track: [], color: colorScheme.sparklineColor, textColor: colorScheme.primaryTextColor,
                                labelSize: labelSize, axisSize: axisSize, segments: segments,
                                gaps: journey.profileGaps.map { gap in
                                    gap.map { ShareCardProfile.Gap(title: $0.ident, detail: $0.detail) }
                                },
                                gapWidth: gapWidth)
    }
}

// MARK: - The leg list

/// Beside the map: each leg, numbered as on the map, with its route, its times and its figures, and
/// each stop's time on the ground between them. Folds as `ShareCardJourneyList` says.
struct JourneyLegList: View {
    let journey: ShareCardJourney
    let layout: ShareCardJourneyLayout
    let height: CGFloat
    let scheme: ShareCardColorScheme
    /// Under the legs when the card has no timeline to say it: "Local time · UTC+2".
    var timeNote: String?

    var body: some View {
        let heights = layout.listHeights
        let noteRoom: CGFloat = timeNote == nil ? 0 : 30
        let (rows, compact) = ShareCardJourneyList.rows(legCount: journey.legs.count, height: height - noteRoom,
                                                        heights: heights)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .leg(let index):
                    legRow(index, compact: compact)
                        .frame(height: compact ? heights.compactLeg : heights.leg, alignment: .center)
                case .ground(let index):
                    groundRow(index, compact: compact)
                        .frame(height: compact ? heights.compactGround : heights.ground)
                case .more(let count):
                    moreRow(count)
                        .frame(height: heights.more)
                }
            }
            if let timeNote {
                Text(verbatim: timeNote)
                    .font(.aero(size: 14))
                    .foregroundColor(scheme.tertiaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: noteRoom, alignment: .bottom)
            }
            Spacer(minLength: 0)
        }
    }

    private var column: CGFloat { layout.legNumberSize + 6 }

    private func legRow(_ index: Int, compact: Bool) -> some View {
        let time = journey.legs[index].flightMinutes.map(ShareCardFigures.formattedDuration(minutes:)) ?? "--:--"
        var span = journey.span(ofLeg: index) ?? "—"
        if journey.namesAircraftPerLeg {
            let flight = journey.legs[index]
            span += " · " + (flight.aircraftRegistration.flatMap(Flight.nonBlank) ?? flight.airplane)
        }
        return HStack(alignment: .top, spacing: 16) {
            Text(verbatim: "\(index + 1)")
                .font(.aero(size: layout.legNumberSize * 0.48, weight: .bold))
                .foregroundColor(.white)
                .frame(width: layout.legNumberSize, height: layout.legNumberSize)
                .background(Circle().fill(JourneyShareCard.routeColor))
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                .frame(width: column)
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Text(verbatim: journey.route(ofLeg: index))
                    .font(.custom(AeroTypeface.monoBold, fixedSize: layout.legRouteFont))
                    .foregroundColor(scheme.primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: compact ? "\(span) · \(time)" : span)
                    .font(.aero(size: layout.legTimeFont))
                    .foregroundColor(scheme.primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !compact {
                    Text(verbatim: journey.figuresLine(ofLeg: index))
                        .font(.aero(size: layout.legFiguresFont))
                        .foregroundColor(scheme.secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, -4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func groundRow(_ index: Int, compact: Bool) -> some View {
        let stop = journey.groundStops.first { $0.afterLeg == index }
        let ident = stop?.ident ?? Flight.unknownAerodrome
        let time = stop?.minutes.map(ShareCardJourney.groundDuration(minutes:))
        return HStack(spacing: 16) {
            DashedLine()
                .stroke(scheme.primaryTextColor.opacity(0.4), style: StrokeStyle(lineWidth: 3, dash: [7, 7]))
                .frame(width: 3)
                .padding(.vertical, compact ? 4 : 0)
                .frame(width: column)
            (Text(verbatim: ident)
                .font(.custom(AeroTypeface.monoBold, fixedSize: layout.legFiguresFont))
                .foregroundColor(scheme.primaryTextColor)
             + Text(verbatim: time.map { " · " + (compact ? $0 : L10n.ShareCard.onTheGround($0)) } ?? "")
                .font(.aero(size: layout.legFiguresFont))
                .foregroundColor(scheme.secondaryTextColor))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
    }

    private func moreRow(_ count: Int) -> some View {
        HStack(spacing: 16) {
            Text(verbatim: "···")
                .font(.aero(size: 28, weight: .bold))
                .foregroundColor(scheme.tertiaryTextColor)
                .frame(width: column)
            Text(verbatim: "+\(count)")
                .font(.aero(size: layout.legTimeFont))
                .foregroundColor(scheme.tertiaryTextColor)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The legs under a wide map

/// Under a map that runs the card's width (a journey east–west): the legs two by two, each on two
/// lines, the route and "10:46 – 12:26 · 1:40". The stops are on the timeline and in the profile.
struct JourneyLegGrid: View {
    let journey: ShareCardJourney
    let layout: ShareCardJourneyLayout
    let scheme: ShareCardColorScheme
    var timeNote: String?

    var body: some View {
        let cells = ShareCardJourneyList.grid(legCount: journey.legs.count, capacity: layout.gridMaxRows * 2)
        let rows = stride(from: 0, to: cells.count, by: 2).map { Array(cells[$0..<min($0 + 2, cells.count)]) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 24) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        self.cell(cell)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if row.count == 1 { Spacer().frame(maxWidth: .infinity) }
                }
                .frame(height: layout.gridRowHeight)
            }
            if let timeNote {
                Text(verbatim: timeNote)
                    .font(.aero(size: 14))
                    .foregroundColor(scheme.tertiaryTextColor)
                    .lineLimit(1)
                    .frame(height: layout.noteHeight, alignment: .bottom)
            }
        }
    }

    @ViewBuilder
    private func cell(_ cell: ShareCardJourneyList.Cell) -> some View {
        switch cell {
        case .leg(let index):
            HStack(spacing: 14) {
                Text(verbatim: "\(index + 1)")
                    .font(.aero(size: layout.gridNumberSize * 0.48, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: layout.gridNumberSize, height: layout.gridNumberSize)
                    .background(Circle().fill(JourneyShareCard.routeColor))
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: journey.route(ofLeg: index))
                        .font(.custom(AeroTypeface.monoBold, fixedSize: layout.gridRouteFont))
                        .foregroundColor(scheme.primaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: journey.gridLine(ofLeg: index))
                        .font(.aero(size: layout.gridTimeFont))
                        .foregroundColor(scheme.secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        case .more(let count):
            HStack(spacing: 14) {
                Text(verbatim: "···")
                    .font(.aero(size: 26, weight: .bold))
                    .foregroundColor(scheme.tertiaryTextColor)
                    .frame(width: layout.gridNumberSize)
                Text(verbatim: "+\(count)")
                    .font(.aero(size: layout.gridRouteFont))
                    .foregroundColor(scheme.tertiaryTextColor)
            }
        }
    }
}

/// A vertical line down the middle of its frame.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - The timeline

/// The day from the first block off to the last block on: taxi in grey, each leg in the air in the
/// route's magenta with its number, each stop hatched with its ident and minutes, the hours under it
/// and the first and last times at its ends (J1).
struct JourneyTimeline: View {
    let journey: ShareCardJourney
    let timeline: ShareCardJourney.Timeline
    let scheme: ShareCardColorScheme
    let isStory: Bool

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let span = max(60, timeline.end.timeIntervalSince(timeline.start))
        let barTop: CGFloat = 10, barHeight: CGFloat = isStory ? 36 : 30
        let text = scheme.primaryTextColor
        func x(_ date: Date) -> CGFloat { size.width * CGFloat(date.timeIntervalSince(timeline.start) / span) }
        let bar = CGRect(x: 0, y: barTop, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: bar, cornerRadius: 6), with: .color(text.opacity(0.04)))

        let stops = journey.groundStops
        for segment in timeline.segments {
            let rect = CGRect(x: x(segment.start), y: barTop, width: max(1, x(segment.end) - x(segment.start)),
                              height: barHeight)
            switch segment.kind {
            case .taxi:
                context.fill(Path(rect), with: .color(text.opacity(0.22)))
            case .air(let leg):
                context.fill(Path(rect), with: .color(JourneyShareCard.routeColor))
                let number = context.resolve(Text(verbatim: "\(leg)")
                    .font(.custom(AeroTypeface.bold, fixedSize: isStory ? 17 : 15))
                    .foregroundColor(.white))
                if number.measure(in: size).width + 6 <= rect.width {
                    context.draw(number, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                }
            case .ground(let index):
                context.fill(Path(rect), with: .color(text.opacity(0.06)))
                var hatch = Path()
                var hx = rect.minX - rect.height
                while hx < rect.maxX {
                    hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: hx + rect.height, y: rect.minY))
                    hx += 10
                }
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.stroke(hatch, with: .color(text.opacity(0.2)), lineWidth: 3)
                }
                let stop = stops.first { $0.afterLeg == index }
                let ident = stop?.ident ?? ""
                let minutes = stop?.minutes.map { " \($0)′" } ?? ""
                for candidate in [ident + minutes, ident] where !candidate.isEmpty {
                    let label = context.resolve(Text(verbatim: candidate)
                        .font(.custom(AeroTypeface.monoBold, fixedSize: isStory ? 15 : 13))
                        .foregroundColor(text.opacity(0.75)))
                    if label.measure(in: size).width + 10 <= rect.width {
                        context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                        break
                    }
                }
            }
        }

        // The hours, then the first and last times at the ends.
        let figures = journey.legs.first.map(journey.figures)
        let labelSize: CGFloat = isStory ? 16 : 14
        let labelY = size.height - 4
        func resolved(_ string: String, bold: Bool) -> GraphicsContext.ResolvedText {
            context.resolve(Text(verbatim: string)
                .font(.custom(bold ? AeroTypeface.bold : AeroTypeface.regular, fixedSize: labelSize))
                .foregroundColor(text.opacity(bold ? 0.7 : 0.55)))
        }
        let first = resolved(figures?.time(timeline.start) ?? "", bold: true)
        let last = resolved(figures?.time(timeline.end) ?? "", bold: true)
        let firstEnd = first.measure(in: size).width
        let lastStart = size.width - last.measure(in: size).width
        context.draw(first, at: CGPoint(x: 0, y: labelY), anchor: .bottomLeading)
        context.draw(last, at: CGPoint(x: size.width, y: labelY), anchor: .bottomTrailing)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = journey.useUTC ? TimeZone(identifier: "UTC")! : journey.localTimeZone
        let step = span > 6 * 3600 ? 2 : 1
        guard var hour = calendar.nextDate(after: timeline.start, matching: DateComponents(minute: 0, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        if step == 2, calendar.component(.hour, from: hour) % 2 == 1 { hour = hour.addingTimeInterval(3600) }
        while hour < timeline.end {
            let hx = x(hour)
            var tick = Path()
            tick.move(to: CGPoint(x: hx, y: barTop + barHeight + 4))
            tick.addLine(to: CGPoint(x: hx, y: barTop + barHeight + 12))
            context.stroke(tick, with: .color(text.opacity(0.35)), lineWidth: 1)
            let label = resolved(figures?.time(hour) ?? "", bold: false)
            let width = label.measure(in: size).width
            if hx - width / 2 > firstEnd + 10, hx + width / 2 < lastStart - 10 {
                context.draw(label, at: CGPoint(x: hx, y: labelY), anchor: .bottom)
            }
            hour = hour.addingTimeInterval(TimeInterval(step * 3600))
        }
    }
}
