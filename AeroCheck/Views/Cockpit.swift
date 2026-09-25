import SwiftUI

// MARK: - Cockpit (v6.0 · P2)
//
// The in-flight screen on iPad: one screen in four fixed zones, built for portrait on a kneeboard.
//
// 1. Header: the aircraft, the phase and where it sits in the flight, flight time, GPS, and a
//    labelled Menu.
// 2. Instrument strip: GS, ALT, TRK and the next waypoint, at `CockpitType.value`.
// 3. The context pane: the CHECKLIST or the MAP at full height, never both squeezed. It follows the
//    flight (`CockpitPaneRule`); a tap on the picker overrides it until the flight moves on.
// 4. The thumb bar: its buttons never move, so the hand learns where they are. Checklist: CHECK and
//    DEFER, next to the phase's own action. Map: MARK, the leg timer, Divert and More.
//
// It replaces the iPad HUD's two layouts (portrait stack, landscape columns), whose map was a
// 200 pt band that opened a full-screen cover. The iPhone keeps its layout until its own pass.

/// What the Cockpit's context pane shows.
enum CockpitPane: Hashable {
    case checklist
    case map
}

/// Which pane the Cockpit shows by itself. Pure, so it is tested without a view.
enum CockpitPaneRule {
    /// The map in climb, cruise and descent once their checklist is worked through; the checklist
    /// everywhere else: on the ground, around take-off and landing, and whenever an en-route checklist
    /// is open, including a cruise check that has come due again.
    static func defaultPane(phase: ChecklistPhase, checklistDone: Bool) -> CockpitPane {
        switch phase {
        case .climb, .cruise, .descent:
            return checklistDone ? .map : .checklist
        default:
            return .checklist
        }
    }
}

/// Where the Cockpit shows its instrument strip: every phase in which the aircraft moves, Taxi to
/// After landing. Before the taxi and after it, GS would only read zero. (on-device review #1, C-14)
enum CockpitStripRule {
    static func showsStrip(in phase: ChecklistPhase) -> Bool {
        (ChecklistPhase.taxi.rawValue...ChecklistPhase.afterLanding.rawValue).contains(phase.rawValue)
    }
}

/// The Cockpit's V-SPEEDS drawer as one fixed table: stall & glide first, then a row per group in the
/// order the speeds are flown. The table is the same in every phase, cell for cell; the phase only
/// decides which cells are highlighted, where they stand. A value that moved with the phase would
/// defeat the pilot's expectancy of where it is (AC 25-11B §6.2.1). (V-SPEEDS proposal, D1–D8)
enum VSpeedTable {
    /// The rows, in their fixed order.
    enum Group: CaseIterable {
        case stallGlide, takeoffClimb, approachLanding, limits, other
    }

    enum Tone {
        case plain
        /// Vso, Vs: a caution, in amber.
        case stall
        /// Vne: the red line.
        case neverExceed
    }

    struct Cell: Equatable, Identifiable {
        /// The speed's index in the checklist's list.
        let id: Int
        let name: String
        let value: String
        /// What the value depends on (the checklist's description), where it matters.
        let qualifier: String?
        let tone: Tone
        let highlighted: Bool
    }

    struct Row: Equatable {
        let group: Group
        let cells: [Cell]
        /// The approach is flown step by step: its cells read as a sequence (›).
        var isSequence: Bool { group == .approachLanding }
        var isHighlighted: Bool { cells.contains { $0.highlighted } }
    }

    enum Crosswind { case takeoff, landing }

    static func group(of name: String) -> Group {
        switch name.lowercased() {
        case "vso", "vs", "vbg", "vne": return .stallGlide
        case "vr", "vinitial", "vx", "vy", "vcc": return .takeoffClimb
        case "vapp", "vfinal", "vref", "vgo": return .approachLanding
        case "vfe", "vfo", "va", "vno": return .limits
        default: return .other
        }
    }

    static func tone(of name: String) -> Tone {
        switch name.lowercased() {
        case "vso", "vs": return .stall
        case "vne": return .neverExceed
        default: return .plain
        }
    }

    /// Every speed exactly once, grouped; empty groups left out. `phase` and `aglFeet` only decide
    /// the highlight.
    static func rows(speeds: [SpeedReference], phase: ChecklistPhase, aglFeet: Double?) -> [Row] {
        let highlighted = highlightedIndexes(speeds: speeds, phase: phase, aglFeet: aglFeet)
        let indexed = Array(speeds.enumerated())
        return Group.allCases.compactMap { group in
            var members = indexed.filter { self.group(of: $0.element.name) == group }
            guard !members.isEmpty else { return nil }
            members.sort { (order(in: group, $0.element.name), $0.offset) < (order(in: group, $1.element.name), $1.offset) }
            let names = members.map { $0.element.name.lowercased() }
            let cells = members.map { index, speed in
                // Approach steps and limits depend on flaps or weight: always qualified. Elsewhere
                // only a name that repeats needs it (two Vx, two Vr).
                let repeated = names.filter { $0 == speed.name.lowercased() }.count > 1
                let qualified = group == .approachLanding || group == .limits || repeated
                return Cell(id: index, name: speed.name, value: compactRange(speed.value),
                            qualifier: qualified && !speed.description.isEmpty ? speed.description : nil,
                            tone: tone(of: speed.name), highlighted: highlighted.contains(index))
            }
            return Row(group: group, cells: cells)
        }
    }

    /// Stall before glide before Vne; the climb as flown; every other row in the checklist's order.
    private static func order(in group: Group, _ name: String) -> Int {
        let key = name.lowercased()
        switch group {
        case .stallGlide: return ["vso", "vs", "vbg", "vne"].firstIndex(of: key) ?? 9
        case .takeoffClimb: return ["vr", "vinitial", "vx", "vy", "vcc"].firstIndex(of: key) ?? 9
        default: return 0
        }
    }

    /// The speeds the phase is flown at. Today's highlight rule (Vr on the line-up, Vx below 300 ft
    /// AGL then Vy, VA and Vbg in the descent, the approach, Vfinal and Vso on landing) with Vinitial
    /// where there's no Vr or Vx, and Vno in cruise where it's listed.
    static func highlightedIndexes(speeds: [SpeedReference], phase: ChecklistPhase, aglFeet: Double?) -> Set<Int> {
        let names = speeds.map { $0.name.lowercased() }
        func all(_ wanted: [String]) -> Set<Int> {
            Set(names.indices.filter { wanted.contains(names[$0]) })
        }
        func first(_ wanted: [String]) -> Set<Int> {
            for name in wanted {
                let hit = all([name])
                if !hit.isEmpty { return hit }
            }
            return []
        }
        switch phase {
        case .beforeDeparture, .lineUp:
            return first(["vr", "vinitial"])
        case .climb:
            let belowTransition = aglFeet.map { $0 < 300 } ?? false
            return belowTransition ? first(["vx", "vinitial", "vy"]) : first(["vy", "vx"])
        case .cruise:
            return all(["vno", "va"])
        case .descent:
            return all(["va", "vbg"])
        case .approach:
            return Set(names.indices.filter { group(of: names[$0]) == .approachLanding && names[$0] != "vgo" })
        case .landing:
            return first(["vfinal", "vref"]).union(all(["vso"]))
        default:
            return []
        }
    }

    /// The crosswind limit that applies: take-off on the line-up, landing on landing.
    static func highlightedCrosswind(phase: ChecklistPhase) -> Crosswind? {
        switch phase {
        case .beforeDeparture, .lineUp: return .takeoff
        case .landing: return .landing
        default: return nil
        }
    }

    /// The checklists write ranges as "97 – 75", "65-55" or "60 - 55"; in a cell they read as one
    /// value: "97–75".
    static func compactRange(_ value: String) -> String {
        value.replacingOccurrences(of: #"(\d)\s*[-–]\s*(\d)"#, with: "$1–$2", options: .regularExpression)
    }
}

/// A thumb-bar button: what it does, in `CockpitType.button`, and what it does it to, underneath.
/// Always `CockpitTarget.thumb` tall.
struct CockpitThumbButton: View {
    enum Style {
        /// The primary action: solid.
        case filled(fill: Color, text: Color)
        /// A secondary action: tinted outline.
        case outlined(tint: Color)
    }

    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    if let icon {
                        Image(systemName: icon).font(.aero(size: CockpitType.response, weight: .bold))
                    }
                    Text(title)
                        .font(.aero(size: CockpitType.button, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.aero(size: CockpitType.label, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(0.85)
                }
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: CockpitTarget.thumb)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var textColor: Color {
        switch style {
        case .filled(_, let text): return text
        case .outlined(let tint): return tint
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .filled(let fill, _):
            RoundedRectangle(cornerRadius: 18).fill(fill)
        case .outlined(let tint):
            RoundedRectangle(cornerRadius: 18)
                .fill(tint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.5), lineWidth: 1.5))
        }
    }
}

/// CHECKLIST | MAP, both words on screen, the current one filled.
struct CockpitPanePicker: View {
    @Environment(\.cockpitTheme) private var theme
    @Binding var selection: CockpitPane

    var body: some View {
        HStack(spacing: 0) {
            segment(.checklist, title: L10n.Cockpit.checklist, icon: "checklist")
            segment(.map, title: L10n.Cockpit.map, icon: "map")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.panelStroke, lineWidth: 1))
    }

    private func segment(_ pane: CockpitPane, title: String, icon: String) -> some View {
        let selected = selection == pane
        return Button { selection = pane } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.aero(size: CockpitType.label, weight: .semibold))
                Text(title).font(.aero(size: CockpitType.label, weight: .bold)).lineLimit(1).fixedSize()
            }
            .foregroundColor(selected ? theme.actionText : theme.action)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? theme.action : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A labelled chip beside the pane picker: V-SPEEDS, BRIEFING, the next phase.
struct CockpitChip: View {
    @Environment(\.cockpitTheme) private var theme
    let title: String
    var icon: String? = nil
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        let color = tint ?? theme.action
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.aero(size: 18, weight: .semibold))
                }
                Text(title).font(.aero(size: CockpitType.label, weight: .bold)).lineLimit(1).fixedSize()
            }
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
