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
