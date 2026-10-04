import SwiftUI
import os
import UIKit

// MARK: - Cockpit (v6.0 · P2)
//
// The in-flight screen on iPad: one screen in four fixed zones, built for portrait on a kneeboard.
//
// 1. Header: the aircraft, the phase and where it sits in the flight, flight time, GPS, and a
//    labelled Menu.
// 2. The read band's live rows (6.2, `CockpitReadBand.swift`): the instrument strip, GS, ALT and TRK at
//    `CockpitType.value` and, on the iPad, NEXT with its bearing, distance, ETE and ETA; then NOW | NEXT,
//    the frequencies (on the phone the next line and the NOW line). Over every page.
// 3. The context page: the CHECKLIST, the MAP or the ROUTE at full height, never two squeezed. It
//    follows the flight (`CockpitPageRule`: CHECKLIST or MAP); a tap on the picker overrides it until
//    the flight moves on (`CockpitPageChoice`). ROUTE (6.2) is the pilot's pick only: the DEST line, the
//    legs and the radio (`CockpitRoutePage.swift`).
// 4. The act band (6.2, `CockpitActBand.swift`): four slots in the same frames under every page, so the
//    hand learns where they are. Checklist: the phase's action, FREDA or the check slot, then CHECK,
//    DEFER and More. Map: the check slot, MARK with the leg timer, Divert and More.
//
// It replaces the iPad HUD's two layouts (portrait stack, landscape columns), whose map was a
// 200 pt band that opened a full-screen cover. Since the iPhone pass the phone has the same Cockpit,
// laid out by `CockpitLayout` and sized by `CockpitScale`.

/// What the Cockpit's context page shows.
enum CockpitPage: Hashable {
    case checklist
    case map
    /// The DEST line, the legs and the radio. Never a default: the pilot picks it. (6.2)
    case route
}

/// The page the pilot picked over the one the flight suggests: kept until the suggestion changes (the
/// next phase, the checklist done), then dropped. Pure, so it is tested without a view. (v6.0 · P2; 6.2)
struct CockpitPageChoice: Equatable {
    /// The pilot's pick, while it differs from the suggestion.
    private(set) var override: CockpitPage?

    init(override: CockpitPage? = nil) {
        self.override = override
    }

    /// What shows.
    func page(suggested: CockpitPage) -> CockpitPage {
        override ?? suggested
    }

    /// A tap on the picker: the suggestion itself clears the pick.
    mutating func pick(_ page: CockpitPage, suggested: CockpitPage) {
        override = page == suggested ? nil : page
    }

    /// The flight suggests another page: the pick is dropped, ROUTE's too.
    mutating func suggestionChanged() {
        override = nil
    }
}

/// Which page the Cockpit shows by itself. Pure, so it is tested without a view.
enum CockpitPageRule {
    /// The map in climb, cruise and descent once their checklist is worked through; the checklist
    /// everywhere else: on the ground, around take-off and landing, and whenever an en-route checklist
    /// is open, including a cruise check that has come due again.
    ///
    /// A memory check (`memoryCheck`: every item hidden by the Memory test) has no list to show: the
    /// map, with the check slot to confirm it, in climb, cruise and descent as before, and since 6.1 in
    /// approach, landing and after landing too, which were near-empty checklist pages (Q7).
    static func defaultPage(phase: ChecklistPhase, checklistDone: Bool, memoryCheck: Bool = false) -> CockpitPage {
        switch phase {
        case .climb, .cruise, .descent:
            return checklistDone || memoryCheck ? .map : .checklist
        case .approach, .landing, .afterLanding:
            return memoryCheck ? .map : .checklist
        default:
            return .checklist
        }
    }
}

/// How the Cockpit lays its zones out for the room it has. Pure, so it is tested without a view.
/// (iPhone pass, I1 and I7)
enum CockpitLayout: Equatable {
    /// The iPad, portrait and landscape: the header and the page bar on one row each.
    case wide
    /// A phone in portrait, or any window under 600 pt wide: the same zones, the header on two rows, and
    /// no NEXT cell in the strip (the next line under it instead).
    case narrow
    /// A phone on its side: the page on the left at full height, and the header, the strip, the next and
    /// NOW lines and the act band in a column on the right, where the thumb is (6.2, PR 5). Stacked, the
    /// zones would leave the checklist about 90 pt.
    case columns

    static func make(width: CGFloat, height: CGFloat) -> CockpitLayout {
        if width > height && height < 500 { return .columns }
        return width < 600 ? .narrow : .wide
    }

    /// The reference drawers' height cap, as a share of the screen.
    var drawerHeightFraction: CGFloat {
        switch self {
        case .wide: return 0.6
        case .narrow: return 0.66
        case .columns: return 0.9
        }
    }
}

/// The side of a phone on its side that needs no clearance: the one away from the front camera. Pure,
/// so it is tested without a device. (round 6, I-09)
enum CameraSideRule {
    /// `.landscapeRight` has the camera on the left; `.landscapeLeft` on the right. Nil in portrait or
    /// while the orientation is unknown, when both sides keep the system's inset.
    static func freeEdge(for orientation: UIInterfaceOrientation) -> Edge.Set? {
        switch orientation {
        case .landscapeRight: return .trailing
        case .landscapeLeft: return .leading
        default: return nil
        }
    }

    /// What the free side keeps: clear of the display's rounded corners, never more than the system's.
    static func margin(systemInset: CGFloat) -> CGFloat { min(systemInset, 16) }
}

/// A phone on its side keeps the system's clearance on the camera's side only. iOS insets both sides
/// alike in landscape, about 60 pt on a Dynamic Island iPhone, which left a band as wide as a thumb
/// unused beside the column. The other side now runs to 16 pt from the edge. (round 6, I-09)
struct CameraSideInset: ViewModifier {
    let enabled: Bool
    /// The system's horizontal inset, the same on both sides in landscape.
    let systemInset: CGFloat
    @State private var orientation: UIInterfaceOrientation = .unknown

    func body(content: Content) -> some View {
        let edge = enabled && systemInset > 0 ? CameraSideRule.freeEdge(for: orientation) : nil
        let margin = CameraSideRule.margin(systemInset: systemInset)
        // The same modifiers whatever the side, so a turn never rebuilds the Cockpit (and the map with
        // its zoom).
        content
            .safeAreaPadding(.leading, edge == .leading ? margin : 0)
            .safeAreaPadding(.trailing, edge == .trailing ? margin : 0)
            .ignoresSafeArea(.container, edges: edge ?? [])
            .background(InterfaceOrientationReader { orientation = $0 })
    }
}

/// Reports the window scene's interface orientation, a turn from one landscape to the other included:
/// that turn changes no size, so nothing would lay out again by itself.
struct InterfaceOrientationReader: UIViewRepresentable {
    let onChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((UIInterfaceOrientation) -> Void)?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            observation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
                let orientation = scene.effectiveGeometry.interfaceOrientation
                DispatchQueue.main.async { self?.onChange?(orientation) }
            }
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
    ///
    /// The table asks for its rows on every GPS fix, since the height is one of its inputs, but the
    /// rows only change with the phase and the side of the climb transition the aircraft is on. The
    /// last answer is kept and given again until one of those changes. (v6.0 review)
    static func rows(speeds: [SpeedReference], phase: ChecklistPhase, aglFeet: Double?) -> [Row] {
        let key = RowsKey(speeds: speeds.map { [$0.name, $0.description, $0.value] }, phase: phase,
                          belowTransition: aglFeet.map { $0 < climbTransitionFeet })
        if let hit = lastRows.withLock({ $0?.key == key ? $0?.rows : nil }) { return hit }
        let rows = makeRows(speeds: speeds, phase: phase, aglFeet: aglFeet)
        lastRows.withLock { $0 = (key, rows) }
        return rows
    }

    /// Below this height, the climb is flown at Vx; above it, at Vy.
    static let climbTransitionFeet: Double = 300

    private struct RowsKey: Equatable {
        let speeds: [[String]]
        let phase: ChecklistPhase
        let belowTransition: Bool?
    }

    private static let lastRows = OSAllocatedUnfairLock<(key: RowsKey, rows: [Row])?>(initialState: nil)

    private static func makeRows(speeds: [SpeedReference], phase: ChecklistPhase, aglFeet: Double?) -> [Row] {
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
            let belowTransition = aglFeet.map { $0 < climbTransitionFeet } ?? false
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
        let range = NSRange(value.startIndex..., in: value)
        return rangePattern.stringByReplacingMatches(in: value, range: range, withTemplate: "$1–$2")
    }

    /// Compiled once: `replacingOccurrences(options: .regularExpression)` compiled it for every cell,
    /// on every fix. (v6.0 review)
    private static let rangePattern = try! NSRegularExpression(pattern: #"(\d)\s*[-–]\s*(\d)"#)
}

/// What the thumb bar's primary says once the check is done: "NEXT: TAXI CHECK" over "All checked" (or
/// what was deferred). Out of the check before departure it is "READY FOR LINE UP" over "then LINE UP
/// CHECK": the radio call the tap stands for, and the moment the take-off is estimated from
/// (`AppState.nextPhase`). The Cockpit's and the Companion iPhone's, so both say the same. (6.2)
struct CockpitNextLabel: Equatable {
    let title: String
    let subtitle: String
    let icon: String
    /// VoiceOver: what the tap does besides going on, when it does more.
    let accessibilityHint: String?

    init(leaving phase: ChecklistPhase?, to next: ChecklistPhase?, deferred: Int) {
        if phase?.readiesForLineUp == true, let next {
            title = L10n.ChecklistAction.readyForLineUp
            subtitle = L10n.Cockpit.thenCheck(next.shortTitle)
            icon = "airplane.departure"
            accessibilityHint = L10n.Cockpit.readyForLineUpHint
        } else {
            title = next.map { L10n.Cockpit.next($0.shortTitle) } ?? L10n.Button.next
            subtitle = deferred > 0 ? L10n.Deferred.count(deferred) : L10n.Cockpit.allChecked
            icon = "chevron.right"
            accessibilityHint = nil
        }
    }
}

/// An act band button: what it does, in `CockpitType.button`, and what it does it to, underneath.
/// At least its slot's height (`CockpitTarget.thumb` outside the band), unless told otherwise.
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
    /// Two in the act band's slots, where a long title ("✓ AFTER ENGINE START CHECK DONE", "READY FOR
    /// LINE UP") or CHECK's item would shrink under the in-flight sizes on one. (6.2)
    var titleLines: Int = 1
    var subtitleLines: Int = 1
    var horizontalPadding: CGFloat = 14
    var minHeight: CGFloat? = nil
    /// The act band's slots on the phone: the words set to fit the slot (`ActFace`), the title on up to
    /// `titleLines`, the subtitle on up to `subtitleLines`, no icon. (6.2)
    var fitted = false
    let action: () -> Void

    @Environment(\.actSlotHeight) private var slotHeight

    var body: some View {
        Button(action: action) {
            Group {
                if fitted {
                    ActFaceText(blocks: fittedBlocks)
                } else {
                    VStack(spacing: 4) {
                        HStack(spacing: 10) {
                            if let icon {
                                Image(systemName: icon).font(.aero(size: CockpitType.response, weight: .bold))
                            }
                            Text(title)
                                .font(.aero(size: CockpitType.button, weight: .bold))
                                .multilineTextAlignment(.center)
                                .lineLimit(titleLines)
                                .minimumScaleFactor(0.6)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.aero(size: CockpitType.label, weight: .medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(subtitleLines)
                                .minimumScaleFactor(0.7)
                                .opacity(0.85)
                        }
                    }
                }
            }
            .foregroundColor(textColor)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight ?? slotHeight ?? CockpitTarget.thumb)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// The title, then the subtitle, as the slot sets them on the phone.
    var fittedBlocks: [ActFaceBlock] {
        var blocks = [ActFaceBlock(text: title, size: CockpitType.button(for: .phone), maxLines: titleLines)]
        if let subtitle, !subtitle.isEmpty {
            blocks.append(ActFaceBlock(text: subtitle, size: CockpitType.label(for: .phone), bold: false,
                                       maxLines: subtitleLines, opacity: 0.85))
        }
        return blocks
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

/// CHECKLIST · MAP · ROUTE, every word on screen, the current one filled.
struct CockpitPagePicker: View {
    @Environment(\.cockpitTheme) private var theme
    @Binding var selection: CockpitPage
    /// The phone's page bar: the segments share the full width.
    var fillsWidth: Bool = false
    /// The icons beside the words, where they fit: a phone in French has room for the words alone.
    var showsIcons: Bool = true
    /// The phone's column on its side: segments 42 pt tall in 2 pt of frame, 46 in all, where the column
    /// has no point to spare (54 elsewhere on the phone). (6.2, PR 5)
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            segment(.checklist, title: L10n.Cockpit.checklist, icon: "checklist")
            segment(.map, title: L10n.Cockpit.map, icon: "map")
            segment(.route, title: L10n.Cockpit.route, icon: "list.bullet")
        }
        .padding(compact ? 2 : 4)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.panelStroke, lineWidth: 1))
    }

    /// A segment's height in the column on its side.
    static let compactSegmentHeight: CGFloat = 42

    /// "pane.checklist", "pane.map", "pane.route": what the UI tests and the replays tap, their 6.0 names.
    static func identifier(_ page: CockpitPage) -> String {
        switch page {
        case .checklist: return "pane.checklist"
        case .map: return "pane.map"
        case .route: return "pane.route"
        }
    }

    private func segment(_ page: CockpitPage, title: String, icon: String) -> some View {
        let selected = selection == page
        return Button { selection = page } label: {
            HStack(spacing: 8) {
                if showsIcons {
                    Image(systemName: icon).font(.aero(size: CockpitType.label, weight: .semibold))
                }
                Text(title).font(.aero(size: CockpitType.label, weight: .bold)).lineLimit(1).fixedSize()
            }
            .foregroundColor(selected ? theme.actionText : theme.action)
            .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 10))
            .frame(maxWidth: fillsWidth ? .infinity : nil,
                   minHeight: compact ? Self.compactSegmentHeight : CockpitType.size(kneeboard: 52, phone: 46))
            .background(RoundedRectangle(cornerRadius: compact ? 12 : 10).fill(selected ? theme.action : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.identifier(page))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A labelled chip beside the page picker: V-SPEEDS, BRIEFING, the next phase.
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
            .padding(.horizontal, CockpitType.size(kneeboard: 14, phone: 10))
            .frame(minHeight: CockpitType.size(kneeboard: 52, phone: 46))
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
