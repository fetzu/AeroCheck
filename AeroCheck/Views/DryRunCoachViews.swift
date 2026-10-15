import SwiftUI

// MARK: - Dry run (6.4.0): the coach on screen

/// Where the Cockpit's controls are, for the coach's ring: each control the guided flight points at says so
/// with `.coachTarget(_:)`. Read only by a dry run's Cockpit; nothing changes for a real flight's.
struct CoachTargetKey: PreferenceKey {
    static var defaultValue: [DryRunCoachStep.Target: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [DryRunCoachStep.Target: Anchor<CGRect>],
                       nextValue: () -> [DryRunCoachStep.Target: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The Cockpit's page, for the coach's "Open MAP".
struct CockpitPageKey: PreferenceKey {
    static var defaultValue: CockpitPage? { nil }

    static func reduce(value: inout CockpitPage?, nextValue: () -> CockpitPage?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// This control, for the guided flight's ring. (6.4.0)
    func coachTarget(_ target: DryRunCoachStep.Target) -> some View {
        anchorPreference(key: CoachTargetKey.self, value: .bounds) { [target: $0] }
    }
}

/// The coach's light card, docked above the act band (D4, Q5 A): the chapter and its progress, what to look at
/// or do, and on a look step Pause and Next.
struct DryRunCoachCard: View {
    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession
    let step: DryRunCoachStep
    let compact: Bool

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private let ink = Color(red: 0.106, green: 0.11, blue: 0.125)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(compact ? L10n.DryRunCoach.chapterOf(step.chapter, DryRunChapters.count)
                             : "\(L10n.DryRunCoach.chapterOf(step.chapter, DryRunChapters.count)) · \(DryRunChapters.title(step.chapter))")
                    .font(.aero(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.7)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(1...DryRunChapters.count, id: \.self) { chapter in
                        Capsule().frame(width: 14, height: 3).opacity(chapter <= step.chapter ? 1 : 0.25)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(step.title)
                .font(.aero(size: compact ? 17 : 19, weight: .bold))
            Text(step.body)
                .font(.aero(size: compact ? 15 : 16))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                if step.kind == .look {
                    button(session.isPaused ? L10n.DryRunCoach.goOn : L10n.DryRunCoach.pause, filled: false) {
                        session.isPaused ? session.resume() : session.pause()
                    }
                    button(L10n.DryRunCoach.next, filled: true) { coach.next() }
                } else if step.target != nil {
                    button(L10n.DryRunCoach.showAgain, filled: false) { coach.showAgain() }
                }
            }
        }
        .foregroundColor(ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(paper))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.aero(size: 15, weight: .bold))
                .foregroundColor(filled ? paper : ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(filled ? ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// The veil and the ring: a do step that is one tap veils the rest of the screen, its control rung and live;
/// any other step with a control only rings it. Nothing when the control isn't on screen (another page).
struct DryRunCoachVeil: View {
    let step: DryRunCoachStep
    let target: CGRect?
    let pulse: Int
    @State private var flash = false

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)

    var body: some View {
        GeometryReader { geo in
            if let target {
                let hole = target.insetBy(dx: -6, dy: -6)
                ZStack {
                    if step.veils {
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: geo.size).insetBy(dx: -400, dy: -400))
                            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16))
                        }
                        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                        .contentShape(Path { path in
                            path.addRect(CGRect(origin: .zero, size: geo.size).insetBy(dx: -400, dy: -400))
                            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16))
                        }, eoFill: true)
                    }
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(paper, lineWidth: 4)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .scaleEffect(flash ? 1.06 : 1, anchor: UnitPoint(x: hole.midX / max(geo.size.width, 1),
                                                                         y: hole.midY / max(geo.size.height, 1)))
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: pulse) { _, _ in
            withAnimation(.easeInOut(duration: 0.25).repeatCount(3, autoreverses: true)) { flash.toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { flash = false }
        }
        .accessibilityHidden(true)
    }
}
