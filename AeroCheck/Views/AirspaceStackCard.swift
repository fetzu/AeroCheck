import CoreLocation
import SwiftUI

// MARK: - The airspace over a point (6.9.0)

/// What a tap on the map shows: every airspace over the point, top down, the aircraft's altitude a line beside it
/// (a12 A). Pure: the rows from the data, the view below draws them.
struct AirspaceStack: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let badge: String
        let name: String
        let limits: String
        let frequency: String?
        let lowerFt: Double
        let upperFt: Double
        let kind: AirspaceMapKind
        /// The aircraft is in this band, as the map's tiers read it (a8 A).
        let holdsAircraft: Bool
        /// What the DABS says of it. (6.9.0, a14 A)
        var note: String? = nil
        /// A Swiss area the DABS has off for now: faded here as on the map.
        var isFaded = false
    }

    static let maxRows = 6
    /// The column's top: nothing a VFR pilot draws above stretches the rest flat.
    static let columnCeilingFt = 11000.0

    let coordinate: CLLocationCoordinate2D
    let altitudeFt: Double?
    let rows: [Row]
    /// A bulletin stands behind a row: the card says it doesn't replace the NOTAMs.
    var mentionsBulletin: Bool { rows.contains { $0.note != nil } }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.altitudeFt == rhs.altitudeFt && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    /// The stack at `coordinate`, or nil with nothing there. More than six: those closest to the aircraft's altitude,
    /// or the lowest with no aircraft, still drawn top down.
    static func make(at coordinate: CLLocationCoordinate2D, from airspaces: [Airspace], altitudeFt: Double?,
                     terrainFt: ClosedRange<Double>? = nil, board: ActivationBoard? = nil) -> AirspaceStack? {
        let over = airspaces.filter { airspace in
            !airspace.isInformationArea && airspace.airspaceType != .fir && airspace.airspaceType != .uir
                && airspace.containsPoint(coordinate)
        }
        var rows = over.map { airspace -> Row in
            let (lower, upper) = AirspaceRelevance.band(airspace, terrainFt: terrainFt)
            let margin = AirspaceRelevance.levelMarginFt
            let holds = altitudeFt.map { lower <= $0 + margin && upper >= $0 - margin } ?? false
            return Row(id: airspace.id, badge: AirspaceTagContent.badge(airspace), name: AirspaceTagContent.name(airspace),
                       limits: "\(AirspaceTagContent.limit(airspace.upperCeiling)) / \(AirspaceTagContent.limit(airspace.lowerCeiling))",
                       frequency: airspace.primaryFrequency?.value, lowerFt: lower, upperFt: upper.isFinite ? upper : columnCeilingFt,
                       kind: airspace.mapKind, holdsAircraft: holds, note: board?.note(for: airspace),
                       isFaded: board.map { !$0.isActive(airspace) } ?? false)
        }
        guard !rows.isEmpty else { return nil }
        if rows.count > maxRows {
            let distance = { (row: Row) -> Double in
                guard let altitudeFt else { return row.lowerFt }
                return max(row.lowerFt - altitudeFt, altitudeFt - row.upperFt, 0)
            }
            rows = Array(rows.sorted { (distance($0), $0.name) < (distance($1), $1.name) }.prefix(maxRows))
        }
        rows.sort { ($0.upperFt, $0.lowerFt, $1.name) > ($1.upperFt, $1.lowerFt, $0.name) }
        return AirspaceStack(coordinate: coordinate, altitudeFt: altitudeFt, rows: rows)
    }
}

/// The card: on the iPad 384 pt wide in the map's left half, on the phone over its lower half (a12 A). A row tapped
/// lights its airspace on the map.
struct AirspaceStackCard: View {
    let stack: AirspaceStack
    @Binding var selected: String?
    let onClose: () -> Void

    @Environment(\.cockpitTheme) private var theme

    private let k: CGFloat = CockpitScale.current == .phone ? 0.85 : 1
    private var rowHeight: CGFloat { 58 * k }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * k) {
            HStack {
                Button(L10n.Button.close, action: onClose)
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(minHeight: 44)
                Spacer()
                Text(L10n.Nav.airspaceHere)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(.white)
            }
            HStack(alignment: .top, spacing: 8 * k) {
                column.frame(width: 56 * k, height: CGFloat(stack.rows.count) * rowHeight + 10)
                VStack(spacing: 4 * k) {
                    ForEach(stack.rows) { row in rowView(row) }
                }
            }
            if stack.mentionsBulletin {
                Text(L10n.Nav.dabsNoNotam)
                    .font(.aero(size: 15 * k))
                    .foregroundColor(Color(white: 0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12 * k)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.118, green: 0.122, blue: 0.145).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityIdentifier("map.airspaceStack")
    }

    private func color(_ kind: AirspaceMapKind) -> Color {
        Color(red: kind.color.red, green: kind.color.green, blue: kind.color.blue)
    }

    private func rowView(_ row: AirspaceStack.Row) -> some View {
        Button {
            selected = selected == row.id ? nil : row.id
        } label: {
            HStack(spacing: 10 * k) {
                Text(row.badge)
                    .font(.aero(size: (row.badge.count == 1 ? 20 : 12) * k, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36 * k, height: 34 * k)
                    .background(RoundedRectangle(cornerRadius: 6).fill(color(row.kind)))
                VStack(alignment: .leading, spacing: 1) {
                    // The name gives way, never the frequency.
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.aero(size: 15 * k))
                            .foregroundColor(Color(white: 0.8))
                            .lineLimit(1)
                        if let frequency = row.frequency {
                            Text(frequency)
                                .font(.aero(size: 15 * k, weight: .semibold))
                                .foregroundColor(.white)
                                .fixedSize()
                        }
                    }
                    Text(row.limits)
                        .font(.system(size: CockpitType.label, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let note = row.note {
                        Text(note)
                            .font(.aero(size: 15 * k))
                            .foregroundColor(Color(white: 0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(row.isFaded ? 0.7 : 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8 * k)
            .frame(minHeight: rowHeight - 4 * k)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(row.holdsAircraft ? 0.1 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected == row.id ? theme.action : Color.white, lineWidth: 2)
                .opacity(row.holdsAircraft || selected == row.id ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// The bands to scale, the aircraft a line across them.
    private var column: some View {
        Canvas { context, size in
            let scale = (size.height - 12) / AirspaceStack.columnCeilingFt
            let y = { (feet: Double) in size.height - 6 - CGFloat(min(max(feet, 0), AirspaceStack.columnCeilingFt)) * scale }
            for row in stack.rows {
                let rect = CGRect(x: 4, y: y(row.upperFt), width: 34 * k, height: max(2, y(row.lowerFt) - y(row.upperFt)))
                context.fill(Path(rect), with: .color(color(row.kind).opacity(row.kind == .classE ? 0.18 : 0.4)))
                context.stroke(Path(rect), with: .color(color(row.kind)),
                               style: StrokeStyle(lineWidth: 1.5, dash: row.kind.dash.map { CGFloat($0) / 2 }))
            }
            if let altitude = stack.altitudeFt {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(altitude)))
                line.addLine(to: CGPoint(x: 42 * k, y: y(altitude)))
                context.stroke(line, with: .color(.white), lineWidth: 2.5)
                var mark = Path()
                mark.move(to: CGPoint(x: 42 * k, y: y(altitude)))
                mark.addLine(to: CGPoint(x: 50 * k, y: y(altitude) - 6))
                mark.addLine(to: CGPoint(x: 50 * k, y: y(altitude) + 6))
                mark.closeSubpath()
                context.fill(mark, with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}
