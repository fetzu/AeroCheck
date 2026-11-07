import CoreLocation
import SwiftUI

// MARK: - The airspace over a point (6.9.0)

/// What a tap on the map shows: every airspace over the point, top down, each limit as the chart's box writes it, ceiling
/// over floor (the author's q7, 5 Nov 2026). Pure: the rows from the data, the view below draws them.
struct AirspaceStack: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let badge: String
        let name: String
        let upper: String
        let lower: String
        let frequency: String?
        let lowerFt: Double
        let upperFt: Double
        let kind: AirspaceMapKind
        /// The aircraft is in this band, as the map's tiers read it (a8 A).
        let holdsAircraft: Bool
        /// What the DABS says of it (6.9.0, a14 A), or abroad a NOTAM (6.10.0).
        var note: String? = nil
        /// The note is the DABS's: the card then says the DABS doesn't replace the NOTAMs.
        var noteIsBulletin = false
        /// A Swiss area the DABS has off for now: faded here as on the map.
        var isFaded = false
    }

    static let maxRows = 6

    let coordinate: CLLocationCoordinate2D
    let altitudeFt: Double?
    let rows: [Row]
    /// A bulletin stands behind a row: the card says it doesn't replace the NOTAMs.
    var mentionsBulletin: Bool { rows.contains { $0.note != nil && $0.noteIsBulletin } }

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
                       upper: AirspaceTagContent.limit(airspace.upperCeiling), lower: AirspaceTagContent.limit(airspace.lowerCeiling),
                       frequency: airspace.primaryFrequency?.value, lowerFt: lower, upperFt: upper,
                       kind: airspace.mapKind, holdsAircraft: holds, note: board?.note(for: airspace),
                       noteIsBulletin: board?.isBulletinNote(for: airspace) ?? false,
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
    /// The ground under the point, on Plan › Map when the app could ask (the author's q8): what makes "2000 AGL" a height.
    var groundFt: Double? = nil
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
                if let heading {
                    Text(heading)
                        .font(.aero(size: CockpitType.label * 0.8, weight: .semibold))
                        .foregroundColor(Color(white: 0.8))
                }
            }
            VStack(spacing: 6 * k) {
                ForEach(stack.rows) { row in rowView(row) }
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

    /// In flight the altitude to read the limits against; on Plan › Map the ground, when it is known.
    private var heading: String? {
        let tens = { (feet: Double) in (Int((feet / 10).rounded()) * 10).formatted() }
        if let altitude = stack.altitudeFt { return L10n.Nav.airspaceCardYou(tens(altitude)) }
        return groundFt.map { L10n.Nav.airspaceCardGround(tens($0)) }
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
                    Text(row.name)
                        .font(.aero(size: 15 * k))
                        .foregroundColor(Color(white: 0.8))
                        .lineLimit(2)
                    if let frequency = row.frequency {
                        Text(frequency)
                            .font(.aero(size: 15 * k, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    if let note = row.note {
                        Text(note)
                            .font(.aero(size: 15 * k))
                            .foregroundColor(Color(white: 0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(row.isFaded ? 0.7 : 1)
                Spacer(minLength: 0)
                limits(row)
                    .opacity(row.isFaded ? 0.7 : 1)
            }
            .padding(.horizontal, 8 * k)
            .padding(.vertical, 6 * k)
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

    /// The chart's box: the ceiling over the floor, so the ground is at the bottom here too.
    private func limits(_ row: AirspaceStack.Row) -> some View {
        VStack(alignment: .trailing, spacing: 2 * k) {
            Text(row.upper)
            Rectangle().fill(Color.white).frame(height: 1.5)
            Text(row.lower)
        }
        .font(.system(size: CockpitType.label, weight: .bold, design: .monospaced))
        .foregroundColor(.white)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
