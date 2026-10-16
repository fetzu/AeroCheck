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

/// The guided flight's card folded to one line between two steps, in the card's place (the proposal's Q4):
/// what the aircraft does, then the next thing for the pilot to do, so a stretch with nothing to tap says so.
struct DryRunFoldedLine: View {
    let text: String
    /// The chapter the next step is in.
    let chapter: Int?
    let compact: Bool

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private let ink = Color(red: 0.106, green: 0.11, blue: 0.125)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let chapter {
                Text(compact ? "\(chapter)" : "\(chapter) · \(DryRunChapters.title(chapter))")
                    .font(.aero(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.aero(size: compact ? 15 : 16))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(paper))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The guided flight on its way to a chapter flown on its own (the proposal's Q6): this, in place of the
/// Cockpit, for the few seconds the flight takes to be flown there. Nothing is asked on the way.
struct DryRunFastForwardCover: View {
    let chapter: Int
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(L10n.DryRunCoach.coverTitle(chapter))
                .font(.aero(size: 15, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundColor(theme.textSecondary)
            Text(DryRunChapters.title(chapter))
                .font(.aero(size: 30, weight: .bold))
                .foregroundColor(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(L10n.DryRunCoach.coverBody)
                .font(.aero(size: 17))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            ProgressView()
                .controlSize(.large)
                .tint(theme.action)
                .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}

/// The coach's card over a screen the Cockpit shows over itself (the engine hours' prompt), where its own
/// layer can't reach: the card alone, at the foot, no veil and no ring.
private struct DryRunCoachOverCover: View {
    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession

    var body: some View {
        if let step = coach.step, step.target == nil, case .hourMeter = step.moment {
            DryRunCoachCard(coach: coach, session: session, step: step,
                            compact: UIDevice.current.userInterfaceIdiom != .pad)
                .frame(maxWidth: 600)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }
}

extension View {
    /// The guided flight's card over this screen, when a dry run's coach has one for it. Nothing in a real
    /// flight (`session` nil). (6.4.0)
    func dryRunCoachCard(_ session: DryRunSession?) -> some View {
        overlay(alignment: .bottom) {
            if let session, let coach = session.coach {
                DryRunCoachOverCover(coach: coach, session: session)
            }
        }
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
