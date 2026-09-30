import SwiftUI
import UIKit

// MARK: - Flight Share Card

/// The image a pilot shares after a flight, in two styles and two formats (6.1, proposal of 29 Sep,
/// part 2, approved as recommended):
///
/// - **Standard** (mockup A): the route and the aerodromes' names, the route as flown with each time
///   over, the chart at its sharpest with the plan's waypoints, block time, distance, maximum
///   altitude and ground speed, the profile with the times over and the take-off and landing on its
///   axis, the four logged times, the credit.
/// - **Full map** (mockup C): the chart edge to edge, fading into the card around the title and a
///   panel of four figures and the profile.
///
/// Either in 9:16 (stories) or 4:5 (feed posts). Every block has a fixed height and the map takes
/// what is left (`ShareCardLayout`), so there is no empty band, and the sheet makes the map image at
/// the exact shape of its frame. Every figure comes from `ShareCardFigures`, the route from
/// `ShareCardRoute`. Fixed fonts by design: rendered to a fixed-size image, not subject to Dynamic
/// Type (UX-24). Numbers are set in proportional B612, whose colon sits where it should (B612 Mono
/// draws "11: 46").
struct FlightShareCard: View {
    let flight: Flight
    let mapImage: UIImage?
    let useUTC: Bool
    var colorScheme: ShareCardColorScheme = .darkBlue
    var terrainData: [(time: Date, elevationFeet: Double)] = []
    /// Distances in NM, else km: the pilot's Settings choice. (6.1)
    var nauticalMiles: Bool = true
    /// What stands in the map's place without a map image. (6.1)
    var mapPlaceholder: ShareCardMapPlaceholder = .noTrack
    /// The small print naming the map and the terrain on the card (`ShareCardFigures.credit`). (6.1)
    var credit: String?
    var style: ShareCardStyle = .standard
    var format: ShareCardFormat = .story
    /// Under the title: "Bressaucourt → Ecuvillens" (`ShareCardFigures.aerodromeLine`).
    var aerodromeLine: String?
    /// The route as flown. Nil: worked out here from the flight's own plan; the sheet passes one
    /// whose reporting points it could qualify from the downloaded data ("E (LSGC)").
    var route: [ShareCardRouteStop]?

    private var figures: ShareCardFigures {
        ShareCardFigures(flight: flight, nauticalMiles: nauticalMiles, useUTC: useUTC)
    }

    private var stops: [ShareCardRouteStop] {
        route ?? Self.route(for: flight)
    }

    /// The route as flown, from the flight's own plan with every time over filled from the track.
    static func route(for flight: Flight) -> [ShareCardRouteStop] {
        ShareCardRoute.flown(flight, plan: flight.flightPlan?.withActualTimesOver(from: flight))
    }

    private var layout: ShareCardLayout {
        Self.layout(for: flight, style: style, format: format, route: stops)
    }

    /// The layout the card is drawn with, which the sheet also needs for the map's shape.
    static func layout(for flight: Flight, style: ShareCardStyle, format: ShareCardFormat,
                       route: [ShareCardRouteStop]) -> ShareCardLayout {
        ShareCardLayout(style: style, format: format, hasRouteStrip: route.count >= 2,
                        hasCounts: ShareCardFigures(flight: flight).showsCounts)
    }

    var body: some View {
        let layout = self.layout
        ZStack(alignment: .top) {
            colorScheme.backgroundColor
            switch style {
            case .standard: standardCard(layout)
            case .fullMap: fullMapCard(layout)
            }
        }
        .frame(width: layout.canvas.width, height: layout.canvas.height)
        .clipped()
    }

    // MARK: - Standard (A)

    private func standardCard(_ layout: ShareCardLayout) -> some View {
        let figures = self.figures
        let map = layout.mapFrame
        return VStack(spacing: 0) {
            topBar(layout)
                .frame(height: layout.topBarHeight)
                .padding(.top, layout.topPadding)
                .padding(.horizontal, layout.textMargin)

            titleBlock(layout, figures: figures)
                .frame(height: layout.titleBlockHeight, alignment: .top)
                .padding(.top, layout.titleGap)
                .padding(.horizontal, layout.textMargin)

            if layout.hasRouteStrip {
                ShareCardRouteStripView(stops: stops, figures: figures, scheme: colorScheme,
                                        width: layout.canvas.width - 2 * layout.textMargin,
                                        nameSize: layout.routeNameFont, timeSize: layout.routeTimeFont)
                    .frame(height: layout.routeHeight, alignment: .top)
                    .padding(.top, layout.routeGap)
                    .padding(.horizontal, layout.textMargin)
            }

            mapView(size: map, cornerRadius: 24)
                .padding(.top, layout.mapGap)

            tilesRow(layout, figures: figures)
                .frame(height: layout.tileHeight)
                .padding(.top, layout.tilesGap)
                .padding(.horizontal, layout.boxMargin)

            if layout.hasProfileHeader {
                profileHeader(figures: figures)
                    .frame(height: layout.profileHeaderHeight)
                    .padding(.top, layout.profileGap)
                    .padding(.horizontal, layout.textMargin)
            }
            profile(figures: figures, marks: true, axis: true, labelSize: layout.format == .story ? 13 : 12,
                    axisSize: layout.format == .story ? 15 : 13)
                .frame(height: layout.profileHeight)
                .background(RoundedRectangle(cornerRadius: 14).fill(colorScheme.cardOverlayColor.opacity(0.6)))
                .padding(.top, layout.hasProfileHeader ? layout.profileHeaderGap : layout.profileGap)
                .padding(.horizontal, layout.boxMargin)

            timesRow(layout, figures: figures)
                .frame(height: layout.timesHeight)
                .padding(.top, layout.timesGap)
                .padding(.horizontal, layout.boxMargin)

            Text(figures.timeNote)
                .font(.aero(size: layout.format == .story ? 14 : 13))
                .foregroundColor(colorScheme.tertiaryTextColor)
                .lineLimit(1)
                .frame(height: layout.noteHeight)
                .padding(.top, layout.noteGap)

            if layout.hasCounts {
                countsRow(layout, figures: figures)
                    .frame(height: layout.countsHeight)
                    .padding(.top, layout.countsGap)
                    .padding(.horizontal, layout.boxMargin)
            }

            Spacer(minLength: 0)

            footer
                .frame(height: layout.footerHeight, alignment: .bottom)
                .padding(.horizontal, layout.textMargin)
                .padding(.bottom, layout.bottomPadding)
        }
    }

    // MARK: - Full map (C)

    private func fullMapCard(_ layout: ShareCardLayout) -> some View {
        let figures = self.figures
        let band = layout.mapFrame
        return ZStack(alignment: .top) {
            mapView(size: band, cornerRadius: 0)
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
                topBar(layout)
                    .frame(height: layout.topBarHeight)
                    .padding(.top, layout.topPadding)
                    .padding(.horizontal, layout.textMargin)
                titleBlock(layout, figures: figures)
                    .frame(height: layout.titleBlockHeight, alignment: .top)
                    .padding(.top, layout.titleGap)
                    .padding(.horizontal, layout.textMargin)
                Spacer(minLength: 0)
                fullMapPanel(layout, figures: figures)
                    .frame(height: layout.panelHeight)
                    .padding(.horizontal, layout.panelMargin)
                    .padding(.bottom, layout.panelMargin)
            }
        }
    }

    private func fullMapPanel(_ layout: ShareCardLayout, figures: ShareCardFigures) -> some View {
        let valueSize: CGFloat = layout.format == .story ? 32 : 28
        return VStack(alignment: .leading, spacing: layout.panelSpacing) {
            HStack(alignment: .top, spacing: 8) {
                panelFigure(figures.blockTime ?? "--:--", L10n.ShareCard.blockTime, size: valueSize)
                panelFigure(figures.distance, L10n.ShareCard.distance, size: valueSize)
                panelFigure(figures.maxAltitude ?? "—", L10n.ShareCard.maxAltitude, size: valueSize)
                panelFigure(figures.airborneSpan ?? "--:--", figures.timeZoneLabel, size: valueSize)
            }
            .frame(height: layout.panelFiguresHeight, alignment: .top)

            profile(figures: figures, marks: false, axis: false, labelSize: 12, axisSize: 13)
                .frame(height: layout.panelProfileHeight)

            footer
                .frame(height: layout.footerHeight, alignment: .bottom)
        }
        .padding(.horizontal, layout.panelPadding + 6)
        .padding(.vertical, layout.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(colorScheme.primaryTextColor.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(colorScheme.primaryTextColor.opacity(0.07), lineWidth: 1))
        )
    }

    private func panelFigure(_ value: String, _ label: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.aero(size: size, weight: .bold))
                .foregroundColor(colorScheme.primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.aero(size: 13, weight: .bold))
                .foregroundColor(colorScheme.secondaryTextColor)
                .tracking(1.4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Top bar

    private func topBar(_ layout: ShareCardLayout) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Text(formattedDate)
                    .font(.aero(size: 22, weight: .semibold))
                    .foregroundColor(colorScheme.secondaryTextColor)
                    .tracking(2)
                    .fixedSize()
                // The pilot's own name for the flight, which goes above the route everywhere else.
                if let name = flight.titleEyebrow {
                    Text(name)
                        .font(.aero(size: 20))
                        .foregroundColor(colorScheme.tertiaryTextColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                if let model = figures.aircraftModel {
                    Text(model)
                        .font(.aero(size: 18, weight: .medium))
                        .foregroundColor(colorScheme.secondaryTextColor)
                        .lineLimit(1)
                }
                Text(flight.aircraftRegistration ?? flight.airplane)
                    .font(.aero(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(colorScheme.accentColor)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(colorScheme.accentColor.opacity(0.15))
                    .overlay(Capsule().stroke(colorScheme.accentColor.opacity(0.3), lineWidth: 1))
            )
        }
    }

    /// The date, in the zone of the times on the card.
    private var formattedDate: String {
        guard let start = flight.startTime else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        if useUTC { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter.string(from: start).uppercased()
    }

    // MARK: - Title

    /// The route ("LSZQ → LSGE", `Flight.title`) over the aerodromes' names; the flight time on the
    /// right, or the interval that stands in for it, named.
    private func titleBlock(_ layout: ShareCardLayout, figures: ShareCardFigures) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(flight.title)
                    .accessibilityLabel(flight.spokenTitle)
                    .font(.aero(size: layout.titleFont, weight: .bold))
                    .foregroundColor(colorScheme.primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let aerodromeLine {
                    Text(aerodromeLine)
                        .font(.aero(size: layout.subtitleFont))
                        .foregroundColor(colorScheme.secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(figures.headlineValue)
                    .font(.aero(size: layout.durationFont, weight: .bold))
                    .foregroundColor(colorScheme.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                Text(figures.headlineLabel)
                    .font(.aero(size: 14, weight: .bold))
                    .foregroundColor(colorScheme.tertiaryTextColor)
                    .tracking(2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    // MARK: - Map

    private func mapView(size: CGSize, cornerRadius: CGFloat) -> some View {
        Group {
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(colorScheme.cardOverlayColor)
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        // Nothing while loading (the sheet shows its spinner); an honest word otherwise.
                        if mapPlaceholder != .loading {
                            VStack(spacing: 16) {
                                Image(systemName: mapPlaceholder == .unavailable ? "wifi.slash" : "map")
                                    .font(.aero(size: 60))
                                    .foregroundColor(colorScheme.tertiaryTextColor)
                                Text(mapPlaceholder == .unavailable ? L10n.ShareCard.mapUnavailable : L10n.FlightDetail.noGPSData)
                                    .font(.aero(size: 24))
                                    .foregroundColor(colorScheme.tertiaryTextColor)
                            }
                        }
                    }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(cornerRadius > 0 ? colorScheme.mapBorderColor : .clear, lineWidth: 1)
        )
    }

    // MARK: - Tiles

    private func tilesRow(_ layout: ShareCardLayout, figures: ShareCardFigures) -> some View {
        HStack(spacing: 12) {
            tile(icon: "timer", value: figures.blockTime ?? "--:--", label: L10n.ShareCard.blockTime, layout)
            tile(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", value: figures.distance,
                 label: L10n.ShareCard.distance, layout)
            tile(icon: "arrow.up.to.line", value: figures.maxAltitude ?? "—",
                 label: L10n.ShareCard.maxAltitudeTile, layout)
            tile(icon: "speedometer", value: figures.maxGroundSpeed ?? "—",
                 label: L10n.ShareCard.maxGroundSpeed, layout)
        }
    }

    private func tile(icon: String, value: String, label: String, _ layout: ShareCardLayout) -> some View {
        VStack(spacing: layout.format == .story ? 8 : 6) {
            Image(systemName: icon)
                .font(.aero(size: layout.format == .story ? 20 : 17, weight: .medium))
                .foregroundColor(colorScheme.accentColor)
            Text(value)
                .font(.aero(size: layout.tileValueFont, weight: .bold))
                .foregroundColor(colorScheme.primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.aero(size: layout.format == .story ? 12 : 11, weight: .bold))
                .foregroundColor(colorScheme.secondaryTextColor)
                .tracking(1.4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(box)
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(colorScheme.cardOverlayColor)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(colorScheme.cardBorderColor, lineWidth: 1))
    }

    // MARK: - Profile

    private func profileHeader(figures: ShareCardFigures) -> some View {
        HStack {
            Text("ALTITUDE PROFILE")
                .font(.aero(size: 14, weight: .bold))
                .foregroundColor(colorScheme.tertiaryTextColor)
                .tracking(2)
            Spacer()
            if let maxAltitude = figures.maxAltitude {
                Text(L10n.ShareCard.peak(maxAltitude))
                    .font(.aero(size: 14, weight: .bold))
                    .foregroundColor(colorScheme.sparklineColor.opacity(0.85))
                    .tracking(1)
            }
        }
    }

    private func profile(figures: ShareCardFigures, marks: Bool, axis: Bool,
                         labelSize: CGFloat, axisSize: CGFloat) -> some View {
        let passes = marks ? stops.filter { $0.role == .waypoint }.compactMap { stop in
            stop.time.map { ShareCardProfile.Mark(time: $0, label: stop.shortName) }
        } : []
        return ShareCardProfile(
            track: flight.gpsTrack,
            terrain: terrainData,
            marks: passes,
            takeoff: axis ? flight.lineUpTime.map { ShareCardProfile.Mark(time: $0, label: figures.time($0)) } : nil,
            landing: axis ? flight.landingTime.map { ShareCardProfile.Mark(time: $0, label: figures.time($0)) } : nil,
            color: colorScheme.sparklineColor,
            textColor: colorScheme.primaryTextColor,
            labelSize: labelSize,
            axisSize: axisSize
        )
    }

    // MARK: - Times and counts

    /// Block off, take-off, landing, block on: the times a pilot logs, in one zone, said once below.
    private func timesRow(_ layout: ShareCardLayout, figures: ShareCardFigures) -> some View {
        HStack(spacing: 0) {
            ForEach(figures.timeCells, id: \.kind) { cell in
                VStack(spacing: layout.format == .story ? 8 : 6) {
                    Circle()
                        .fill(color(of: cell.kind))
                        .frame(width: 10, height: 10)
                    Text(cell.value)
                        .font(.aero(size: layout.timeValueFont, weight: .bold))
                        .foregroundColor(colorScheme.primaryTextColor)
                        .lineLimit(1)
                    Text(label(of: cell.kind))
                        .font(.aero(size: layout.format == .story ? 12 : 11, weight: .bold))
                        .foregroundColor(colorScheme.tertiaryTextColor)
                        .tracking(1.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(box)
    }

    private func color(of kind: ShareCardFigures.TimeCell.Kind) -> Color {
        switch kind {
        case .blockOff, .blockOn: return colorScheme.secondaryTextColor
        case .takeoff: return .aviationGreen
        case .landing: return .aviationAmber
        }
    }

    private func label(of kind: ShareCardFigures.TimeCell.Kind) -> String {
        switch kind {
        case .blockOff: return L10n.ShareCard.blockOff
        case .takeoff: return L10n.ShareCard.takeoff
        case .landing: return L10n.ShareCard.landing
        case .blockOn: return L10n.ShareCard.blockOn
        }
    }

    /// Circuits and stops: the landings, the touch-and-goes and go-arounds side by side (a
    /// go-around used to hide them), stop-and-goes back at an aerodrome of the flight and full stops
    /// elsewhere (`ShareCardFigures.intermediateFullStops` has the rule).
    private func countsRow(_ layout: ShareCardLayout, figures: ShareCardFigures) -> some View {
        let counts = figures.counts
        var cells: [(icon: String, value: Int, label: String, color: Color)] = []
        if counts.landings > 0 {
            cells.append(("airplane.arrival", counts.landings, L10n.ShareCard.landings(counts.landings), .aviationAmber))
        }
        if counts.touchAndGoes > 0 {
            cells.append(("arrow.triangle.2.circlepath", counts.touchAndGoes,
                          L10n.ShareCard.touchAndGoes(counts.touchAndGoes), .altimeterBlue))
        }
        if counts.goArounds > 0 {
            cells.append(("arrow.up.right.circle.fill", counts.goArounds,
                          L10n.ShareCard.goArounds(counts.goArounds), .aviationRed))
        }
        if counts.stopAndGoes > 0 {
            cells.append(("stop.circle", counts.stopAndGoes, L10n.ShareCard.stopAndGoes(counts.stopAndGoes), .aviationAmber))
        }
        if counts.stops > 0 {
            cells.append(("mappin.and.ellipse", counts.stops, L10n.ShareCard.stops(counts.stops), .aviationAmber))
        }
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                HStack(spacing: 10) {
                    Image(systemName: cell.icon)
                        .font(.aero(size: layout.format == .story ? 20 : 17))
                        .foregroundColor(cell.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(figures.number(cell.value))
                            .font(.aero(size: layout.format == .story ? 26 : 22, weight: .bold))
                            .foregroundColor(colorScheme.primaryTextColor)
                        Text(cell.label)
                            .font(.aero(size: 11, weight: .bold))
                            .foregroundColor(colorScheme.tertiaryTextColor)
                            .tracking(1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(box)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom) {
            // The sources the map and the terrain came from, where the README says they must be
            // credited (6.1)
            if let credit {
                Text(credit)
                    .font(.aero(size: 13, weight: .medium))
                    .foregroundColor(colorScheme.tertiaryTextColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.circle.fill")
                        .font(.aero(size: 26))
                        .foregroundColor(colorScheme.footerIconColor)
                    Text("AéroCheck")
                        .font(.aero(size: 22, weight: .semibold))
                        .foregroundColor(colorScheme.footerTextColor)
                }
                // Verbatim: as a localized key it became a link and took the link blue. (6.1)
                Text(verbatim: "aerocheck.app")
                    .font(.aero(size: 13, weight: .medium))
                    .foregroundColor(colorScheme.footerUrlColor)
            }
        }
    }
}

// MARK: - Route strip

/// The route as flown under the title: a dot per point on one line, green at the start and red at
/// the end, the name in the long form and the time over under each. (6.1)
struct ShareCardRouteStripView: View {
    let stops: [ShareCardRouteStop]
    let figures: ShareCardFigures
    let scheme: ShareCardColorScheme
    let width: CGFloat
    var nameSize: CGFloat = 19
    var timeSize: CGFloat = 16

    private var nameFont: UIFont {
        UIFont(name: AeroTypeface.monoBold, size: nameSize) ?? .monospacedSystemFont(ofSize: nameSize, weight: .bold)
    }
    private var timeFont: UIFont {
        UIFont(name: AeroTypeface.regular, size: timeSize) ?? .systemFont(ofSize: timeSize)
    }

    private func text(_ stop: ShareCardRouteStop) -> String { stop.time.map(figures.time) ?? "" }

    private func width(of stop: ShareCardRouteStop) -> CGFloat {
        let name = (stop.name as NSString).size(withAttributes: [.font: nameFont]).width
        let time = (text(stop) as NSString).size(withAttributes: [.font: timeFont]).width
        return (max(name, time) + 2).rounded(.up)
    }

    var body: some View {
        let placed = ShareCardRouteStrip.layout(stops, width: width, labelWidth: width(of:))
        let dotY: CGFloat = 11
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(scheme.routeLineColor)
                .frame(width: width, height: 4)
                .offset(y: dotY - 2)
            ForEach(Array(placed.enumerated()), id: \.offset) { index, item in
                switch item.item {
                case .stop(let stop):
                    let end = stop.role != .waypoint
                    let size: CGFloat = end ? 18 : 13
                    Circle()
                        .fill(stop.role == .departure ? Color.aviationGreen
                              : stop.role == .arrival ? Color.aviationRed : scheme.routeDotColor)
                        .frame(width: size, height: size)
                        .overlay(Circle().stroke(scheme.backgroundColor, lineWidth: 3).padding(-1.5))
                        .position(x: item.dotX, y: dotY)
                    VStack(alignment: alignment(index, of: placed.count), spacing: 4) {
                        Text(stop.name)
                            .font(.custom(AeroTypeface.monoBold, fixedSize: nameSize))
                            .foregroundColor(end ? scheme.primaryTextColor : scheme.primaryTextColor.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(text(stop))
                            .font(.custom(AeroTypeface.regular, fixedSize: timeSize))
                            .foregroundColor(scheme.primaryTextColor.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: item.labelWidth, alignment: frameAlignment(index, of: placed.count))
                    .offset(x: item.labelX, y: 30)
                case .more(let count):
                    Text(verbatim: "···")
                        .font(.custom(AeroTypeface.bold, fixedSize: 24))
                        .foregroundColor(scheme.tertiaryTextColor)
                        .padding(.horizontal, 4)
                        .background(scheme.backgroundColor)
                        .position(x: item.dotX, y: dotY - 2)
                    Text(verbatim: "+\(count)")
                        .font(.custom(AeroTypeface.regular, fixedSize: timeSize))
                        .foregroundColor(scheme.tertiaryTextColor)
                        .frame(width: item.labelWidth)
                        .offset(x: item.labelX, y: 30)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stops.map(\.name).joined(separator: ", "))
    }

    private func alignment(_ index: Int, of count: Int) -> HorizontalAlignment {
        index == 0 ? .leading : (index == count - 1 ? .trailing : .center)
    }

    private func frameAlignment(_ index: Int, of count: Int) -> Alignment {
        index == 0 ? .leading : (index == count - 1 ? .trailing : .center)
    }
}

// MARK: - Altitude profile

/// The altitude over time, with the terrain under it when fetched: grid lines every 1 000 ft, the
/// times over the waypoints flown as dashed marks with their names, and the take-off and landing on
/// the axis with their times. One `Canvas`, which `ImageRenderer` draws like any view. (6.1:
/// replaces the Charts sparkline and the four stacked paths.)
struct ShareCardProfile: View {
    struct Mark: Equatable {
        let time: Date
        let label: String
    }

    let track: [GPSPoint]
    var terrain: [(time: Date, elevationFeet: Double)] = []
    var marks: [Mark] = []
    var takeoff: Mark?
    var landing: Mark?
    var color: Color = .altimeterBlue
    var textColor: Color = .white
    var labelSize: CGFloat = 13
    var axisSize: CGFloat = 15

    private static let terrainColor = Color(red: 0.45, green: 0.32, blue: 0.18)

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let first = track.first?.timestamp, let last = track.last?.timestamp, track.count >= 2 else { return }
        let span = max(1, last.timeIntervalSince(first))
        let top: CGFloat = marks.isEmpty ? 12 : labelSize + 17
        let bottom: CGFloat = (takeoff == nil && landing == nil) ? 8 : axisSize + 19
        let plot = CGRect(x: 14, y: top, width: size.width - 28, height: max(10, size.height - top - bottom))

        let altitudes = track.map { $0.altitude * 3.28084 }
        let ground = track.map { terrainElevation(at: $0.timestamp) }
        let values = altitudes + ground.compactMap { $0 }
        let low = max(0, ((values.min() ?? 0) - 200) / 100).rounded(.down) * 100
        let high = max(low + 500, (((values.max() ?? 1000) + 300) / 100).rounded(.up) * 100)
        func x(_ time: Date) -> CGFloat { plot.minX + plot.width * CGFloat(time.timeIntervalSince(first) / span) }
        func y(_ feet: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((feet - low) / (high - low)) }

        // Grid, every 1 000 ft.
        var level = (low / 1000).rounded(.down) * 1000 + 1000
        while level < high {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(level)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
            context.stroke(line, with: .color(textColor.opacity(0.06)), lineWidth: 1)
            level += 1000
        }

        func area(_ series: [Double]) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: x(track[0].timestamp), y: plot.maxY))
            for (point, feet) in zip(track, series) { path.addLine(to: CGPoint(x: x(point.timestamp), y: y(feet))) }
            path.addLine(to: CGPoint(x: x(last), y: plot.maxY))
            path.closeSubpath()
            return path
        }
        func line(_ series: [Double]) -> Path {
            var path = Path()
            for (index, (point, feet)) in zip(track, series).enumerated() {
                let p = CGPoint(x: x(point.timestamp), y: y(feet))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }
        let gradient = { (colors: [Color]) in
            GraphicsContext.Shading.linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: plot.minY),
                                                   endPoint: CGPoint(x: 0, y: plot.maxY))
        }
        context.fill(area(altitudes), with: gradient([color.opacity(0.45), color.opacity(0.05)]))
        if !terrain.isEmpty {
            let terrainSeries = ground.map { $0 ?? low }
            context.fill(area(terrainSeries), with: gradient([Self.terrainColor.opacity(0.95), Self.terrainColor.opacity(0.6)]))
            context.stroke(line(terrainSeries), with: .color(Self.terrainColor), lineWidth: 1.5)
        }
        context.stroke(line(altitudes), with: .color(color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2.6, lineJoin: .round))

        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(baseline, with: .color(textColor.opacity(0.12)), lineWidth: 1)

        // The waypoints flown: a dashed mark at each time over, the name above it where it fits.
        var lastLabelEnd = -CGFloat.infinity
        for mark in marks where mark.time >= first && mark.time <= last {
            let mx = x(mark.time)
            var tick = Path()
            tick.move(to: CGPoint(x: mx, y: top - 4))
            tick.addLine(to: CGPoint(x: mx, y: plot.maxY))
            context.stroke(tick, with: .color(textColor.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            let text = context.resolve(Text(mark.label)
                .font(.custom(AeroTypeface.monoBold, fixedSize: labelSize))
                .foregroundColor(textColor.opacity(0.62)))
            let width = text.measure(in: size).width
            let minX = min(max(mx - width / 2, 0), size.width - width)
            guard minX >= lastLabelEnd + 8 else { continue }
            context.draw(text, at: CGPoint(x: minX, y: top - 8), anchor: .bottomLeading)
            lastLabelEnd = minX + width
        }

        // Take-off and landing on the axis, with their times under it.
        for (mark, dot, leading) in [(takeoff, Color.aviationGreen, true), (landing, Color.aviationAmber, false)] {
            guard let mark, mark.time >= first.addingTimeInterval(-60), mark.time <= last.addingTimeInterval(60) else { continue }
            let mx = min(max(x(mark.time), plot.minX), plot.maxX)
            context.fill(Path(ellipseIn: CGRect(x: mx - 5, y: plot.maxY - 5, width: 10, height: 10)), with: .color(dot))
            let text = context.resolve(Text(mark.label)
                .font(.custom(AeroTypeface.bold, fixedSize: axisSize))
                .foregroundColor(textColor.opacity(0.7)))
            let width = text.measure(in: size).width
            let minX = leading ? min(mx, size.width - width) : max(mx - width, 0)
            context.draw(text, at: CGPoint(x: minX, y: size.height - 6), anchor: .bottomLeading)
        }
    }

    /// The terrain under a fix, interpolated between the fetched samples; nil without terrain.
    private func terrainElevation(at time: Date) -> Double? {
        guard let firstSample = terrain.first else { return nil }
        guard terrain.count >= 2 else { return firstSample.elevationFeet }
        if time <= firstSample.time { return firstSample.elevationFeet }
        for (a, b) in zip(terrain, terrain.dropFirst()) where time <= b.time {
            let span = b.time.timeIntervalSince(a.time)
            let fraction = span > 0 ? time.timeIntervalSince(a.time) / span : 0
            return a.elevationFeet + fraction * (b.elevationFeet - a.elevationFeet)
        }
        return terrain.last?.elevationFeet
    }
}
