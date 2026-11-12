import SwiftUI

/// The handbook's chart, drawn by the app from the data's corners: mass against CG, the envelope of
/// each category, and the take-off, landing and empty-tanks points with the fuel line between them.
/// (6.11.0, the author's m6)
///
/// Each point has its own shape (a triangle up, a triangle down, a ring), so nothing depends on
/// colour; a point outside is drawn in the warning colour as well. VoiceOver gets the sentences of
/// `MassBalanceWords.spoken` instead of the drawing.
struct MassBalanceChart: View {
    let data: AircraftMassBalance
    let result: MassBalanceResult
    var compact: Bool = false

    var body: some View {
        Canvas { context, size in
            draw(&context, size)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
        .accessibilityElement()
        .accessibilityLabel(MassBalanceWords.spoken(result, data: data))
    }

    private var points: [MassBalancePoint] { [result.takeoff, result.landing, result.emptyTanks].compactMap { $0 } }

    /// The ranges shown: every corner and every point, with a little air around them.
    private var ranges: (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let corners = data.categories.flatMap(\.envelope)
        let arms = corners.map(\.arm) + points.map(\.arm)
        let masses = corners.map(\.mass) + points.map(\.mass)
        let x0 = arms.min() ?? 0, x1 = arms.max() ?? 1, y0 = masses.min() ?? 0, y1 = masses.max() ?? 1
        let padX = max((x1 - x0) * 0.08, .leastNonzeroMagnitude), padY = max((y1 - y0) * 0.06, .leastNonzeroMagnitude)
        return ((x0 - padX)...(x1 + padX), (y0 - padY)...(y1 + padY))
    }

    /// A round step that gives about `count` ticks over a span.
    static func step(for span: Double, count: Double) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / count
        let magnitude = pow(10, floor(log10(raw)))
        let scaled = raw / magnitude
        let nice: Double = scaled < 1.5 ? 1 : scaled < 3.5 ? 2 : scaled < 7.5 ? 5 : 10
        return nice * magnitude
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let fontSize: CGFloat = compact ? 11 : 13
        let left: CGFloat = compact ? 44 : 56, bottom: CGFloat = compact ? 34 : 42, top: CGFloat = 12, right: CGFloat = 14
        let plot = CGRect(x: left, y: top, width: max(size.width - left - right, 10), height: max(size.height - top - bottom, 10))
        let range = ranges
        func x(_ arm: Double) -> CGFloat {
            plot.minX + CGFloat((arm - range.x.lowerBound) / (range.x.upperBound - range.x.lowerBound)) * plot.width
        }
        func y(_ mass: Double) -> CGFloat {
            plot.maxY - CGFloat((mass - range.y.lowerBound) / (range.y.upperBound - range.y.lowerBound)) * plot.height
        }
        let dim = Color.dimText, grid = Color.white.opacity(0.08)

        context.fill(Path(plot), with: .color(Color.panelBackground))

        // Grid and ticks.
        let stepX = Self.step(for: range.x.upperBound - range.x.lowerBound, count: compact ? 4 : 6)
        var tickX = (range.x.lowerBound / stepX).rounded(.up) * stepX
        while tickX <= range.x.upperBound {
            var line = Path(); line.move(to: CGPoint(x: x(tickX), y: plot.minY)); line.addLine(to: CGPoint(x: x(tickX), y: plot.maxY))
            context.stroke(line, with: .color(grid), lineWidth: 1)
            let decimals = stepX >= 1 ? 0 : (stepX >= 0.1 ? 1 : 2)
            context.draw(Text(MassBalanceWords.plain(tickX, decimals: decimals)).font(.system(size: fontSize, design: .monospaced)).foregroundColor(dim),
                         at: CGPoint(x: x(tickX), y: plot.maxY + fontSize * 0.9))
            tickX += stepX
        }
        let stepY = Self.step(for: range.y.upperBound - range.y.lowerBound, count: compact ? 4 : 6)
        var tickY = (range.y.lowerBound / stepY).rounded(.up) * stepY
        while tickY <= range.y.upperBound {
            var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y(tickY))); line.addLine(to: CGPoint(x: plot.maxX, y: y(tickY)))
            context.stroke(line, with: .color(grid), lineWidth: 1)
            context.draw(Text(MassBalanceWords.plain(tickY, decimals: 0)).font(.system(size: fontSize, design: .monospaced)).foregroundColor(dim),
                         at: CGPoint(x: plot.minX - 6, y: y(tickY)), anchor: .trailing)
            tickY += stepY
        }
        context.draw(Text(L10n.MassBalance.chartCgAxis(MassBalanceWords.armUnit(data.units))).font(.system(size: fontSize)).foregroundColor(dim),
                     at: CGPoint(x: plot.midX, y: size.height - fontSize * 0.7))

        // The envelopes: the category the sheet checks filled, the others as a dashed outline.
        for (index, category) in data.categories.enumerated().reversed() {
            var path = Path()
            for (i, corner) in category.envelope.enumerated() {
                let point = CGPoint(x: x(corner.arm), y: y(corner.mass))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            if index == 0 {
                context.fill(path, with: .color(Color.aviationGreen.opacity(0.14)))
                context.stroke(path, with: .color(Color.primaryText), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            } else {
                context.stroke(path, with: .color(Color.aviationGold.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                if let top = category.envelope.map(\.mass).max(), let leftArm = category.envelope.map(\.arm).min() {
                    context.draw(Text(MassBalanceWords.category(category.id)).font(.system(size: fontSize)).foregroundColor(Color.aviationGold),
                                 at: CGPoint(x: x(leftArm) + 6, y: y(top) + fontSize * 0.8), anchor: .leading)
                }
            }
        }

        // The fuel line: solid from take-off to landing, dashed on down to empty tanks.
        if let takeoff = result.takeoff, let empty = result.emptyTanks {
            let middle = result.landing ?? takeoff
            var burnt = Path(); burnt.move(to: CGPoint(x: x(takeoff.arm), y: y(takeoff.mass))); burnt.addLine(to: CGPoint(x: x(middle.arm), y: y(middle.mass)))
            context.stroke(burnt, with: .color(Color.altimeterBlue), lineWidth: 2)
            var rest = Path(); rest.move(to: CGPoint(x: x(middle.arm), y: y(middle.mass))); rest.addLine(to: CGPoint(x: x(empty.arm), y: y(empty.mass)))
            context.stroke(rest, with: .color(Color.altimeterBlue), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
        }

        func colour(_ point: MassBalancePoint) -> Color { point.isInside ? Color.primaryText : Color.aviationRed }
        func label(_ text: String, _ point: MassBalancePoint, dy: CGFloat) {
            let at = CGPoint(x: x(point.arm), y: y(point.mass))
            let onRight = at.x < plot.maxX - (compact ? 80 : 110)
            context.draw(Text(text).font(.system(size: fontSize, weight: .bold)).foregroundColor(colour(point)),
                         at: CGPoint(x: at.x + (onRight ? 12 : -12), y: at.y + dy), anchor: onRight ? .leading : .trailing)
        }
        let s: CGFloat = compact ? 7 : 9
        if let empty = result.emptyTanks {
            let at = CGPoint(x: x(empty.arm), y: y(empty.mass))
            let ring = Path(ellipseIn: CGRect(x: at.x - s * 0.7, y: at.y - s * 0.7, width: s * 1.4, height: s * 1.4))
            context.fill(ring, with: .color(Color.panelBackground))
            context.stroke(ring, with: .color(colour(empty)), lineWidth: 2.5)
            label(L10n.MassBalance.pointEmptyTanks, empty, dy: fontSize)
        }
        if let landing = result.landing {
            let at = CGPoint(x: x(landing.arm), y: y(landing.mass))
            var down = Path(); down.move(to: CGPoint(x: at.x, y: at.y + s)); down.addLine(to: CGPoint(x: at.x + s, y: at.y - s * 0.8)); down.addLine(to: CGPoint(x: at.x - s, y: at.y - s * 0.8)); down.closeSubpath()
            context.fill(down, with: .color(colour(landing)))
            label(L10n.MassBalance.pointLanding, landing, dy: 0)
        }
        if let takeoff = result.takeoff {
            let at = CGPoint(x: x(takeoff.arm), y: y(takeoff.mass))
            var up = Path(); up.move(to: CGPoint(x: at.x, y: at.y - s)); up.addLine(to: CGPoint(x: at.x + s, y: at.y + s * 0.8)); up.addLine(to: CGPoint(x: at.x - s, y: at.y + s * 0.8)); up.closeSubpath()
            context.fill(up, with: .color(colour(takeoff)))
            label(L10n.MassBalance.pointTakeoff, takeoff, dy: -fontSize)
        }
    }
}
