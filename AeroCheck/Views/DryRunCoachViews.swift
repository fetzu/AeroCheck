import SwiftUI
import UIKit
import Combine

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
    /// This control, for the guided flight's ring. (6.4.0) Merged with what the view's own controls say: a
    /// plain `anchorPreference` on a container replaced its children's, so the chapter bar hid PREPARE's ring
    /// and Show me again had nothing to show (the author's second dry run checks, st-4).
    func coachTarget(_ target: DryRunCoachStep.Target) -> some View {
        transformAnchorPreference(key: CoachTargetKey.self, value: .bounds) { $0[target] = $1 }
    }

    /// This control, when it is one the guided flight rings (`target` not nil).
    @ViewBuilder
    func coachTarget(ifAny target: DryRunCoachStep.Target?) -> some View {
        if let target { coachTarget(target) } else { self }
    }

    /// A dry run's coach's step, once it is the coach's: `$step` publishes before the step changes, and a scroll
    /// made then redraws the screen, its coach's card with it, with the step before. (6.4.0)
    func onDryRunCoachStep(_ session: DryRunSession?, perform: @escaping (DryRunCoachStep) -> Void) -> some View {
        onReceive(session?.coach?.$step.compactMap { $0 }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
                  ?? Empty<DryRunCoachStep, Never>().eraseToAnyPublisher(), perform: perform)
    }

    /// This ground screen, for a dry run's coach: it says it is on show, and the coach's card for it shows over
    /// it, with its veil and its ring. Nothing at all for the app's own screens (no dry run in the
    /// environment). (6.4.0)
    func dryRunCoachScreen(_ screen: DryRunCoachStep.Screen) -> some View {
        modifier(DryRunCoachScreen(screen: screen))
    }
}

private struct DryRunCoachScreen: ViewModifier {
    let screen: DryRunCoachStep.Screen
    @Environment(\.dryRunSession) private var session
    /// The link the dry run kept from opening, said on the screen it was tapped on: said from the ground
    /// under the flight's page, the alert closed the page (the author's second dry run checks, st-6).
    @State private var keptLink: URL?

    func body(content: Content) -> some View {
        if let session, let coach = session.coach {
            content
                // A screen over the ground (the flight's page is a cover) keeps the band on top.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if screen == .flightPage { DryRunGroundBand(session: session) }
                }
                .overlayPreferenceValue(CoachTargetKey.self) { anchors in
                    DryRunGroundCoachLayer(coach: coach, session: session, screen: screen, anchors: anchors)
                }
                .onAppear { coach.show(screen) }
                .onDisappear { coach.hide(screen) }
                .environment(\.openURL, OpenURLAction { url in
                    keptLink = url
                    coach.noteLink()
                    return .handled
                })
                .alert(L10n.DryRunCoach.linkKeptTitle, isPresented: Binding(get: { keptLink != nil },
                                                                             set: { if !$0 { keptLink = nil } })) {
                    Button(L10n.Subscription.ok) { keptLink = nil }
                } message: {
                    Text(L10n.DryRunCoach.linkKept(keptLink.map(DryRunGroundView.place) ?? ""))
                }
        } else {
            content
        }
    }
}

/// The coach over one of the ground's screens: its step's card at the foot, the veil and the ring over its
/// control, when the step is this screen's.
private struct DryRunGroundCoachLayer: View {
    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession
    let screen: DryRunCoachStep.Screen
    let anchors: [DryRunCoachStep.Target: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let step = coach.step, step.screen == screen, step.kind == .partEnd {
                DryRunPartEndPage(coach: coach, session: session, step: step)
            } else if let step = coach.step, step.screen == screen {
                if Self.isSystemBarItem(coach.resolvedTarget(of: step)) {
                    // The tab bar and a sheet's navigation bar are UIKit's: looked for twice a second, as they
                    // may come after the card.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        content(step, target: Self.systemFrame(of: coach.resolvedTarget(of: step), in: proxy), proxy: proxy)
                    }
                } else {
                    content(step, target: coach.resolvedTarget(of: step).flatMap { anchors[$0] }.map { proxy[$0] },
                            proxy: proxy)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: coach.step)
    }

    /// The veil, the ring, and the card: at the foot, or at the top when what it rings is in the lower half
    /// (the author's second dry run checks: the card stood over CREATE FLIGHT, st-3).
    private func content(_ step: DryRunCoachStep, target: CGRect?, proxy: GeometryProxy) -> some View {
        let wide = proxy.size.width >= 600
        let atTop = target.map { $0.midY > proxy.size.height * 0.5 } ?? false
        return ZStack {
            DryRunCoachVeil(step: step, target: target, pulse: coach.pulse)
            DryRunCoachCard(coach: coach, session: session, step: step, compact: !wide)
                .frame(maxWidth: wide ? 600 : .infinity)
                .padding(.horizontal, 12)
                .padding(atTop ? .top : .bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atTop ? .top : .bottom)
                .transition(.opacity)
        }
    }

    /// Whether the target is drawn by UIKit, where the anchors don't reach: the Logbook tab, a sheet's Done.
    static func isSystemBarItem(_ target: DryRunCoachStep.Target?) -> Bool {
        target == .logbookTab || target == .sheetDone
    }

    /// The system bar's item, in the layer's own coordinates: the Logbook tab by its word; a sheet's Done as its
    /// navigation bar's trailing item (iOS 26 draws the bar's buttons with SwiftUI, no label to find).
    static func systemFrame(of target: DryRunCoachStep.Target?, in proxy: GeometryProxy) -> CGRect? {
        let global = target == .sheetDone ? SystemTabItemLocator.trailingBarItemFrame()
                                          : SystemTabItemLocator.frame(of: L10n.Ground.logbook)
        guard let global else { return nil }
        let origin = proxy.frame(in: .global).origin
        return global.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

/// An item of a system bar, which SwiftUI's anchors don't reach: the visible UIKit label reading `title` in
/// the screen on top, and the item around it, its frame in the window (SwiftUI's global space). Nil when there
/// is none. For the coach's ring on the Logbook tab and on a sheet's Done. (6.4.0, the author's second dry run
/// checks, st-19, and sixth, r6-1)
@MainActor
enum SystemTabItemLocator {
    static func frame(of title: String) -> CGRect? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
        for window in windows {
            // The screen on top (the dry run's cover): the app's own tab bar under it says the same word.
            guard var top = window.rootViewController else { continue }
            while let presented = top.presentedViewController { top = presented }
            guard let label = label(titled: title, in: top.view) else { continue }
            // Out to the tab's own view: the item around the label, no wider than a tab.
            var item: UIView = label
            while let parent = item.superview, parent.bounds.width <= 160, parent.bounds.height <= 64 { item = parent }
            return item.convert(item.bounds, to: window)
        }
        return nil
    }

    /// The trailing item of the navigation bar of the screen on top (a sheet's Done), its frame in the window.
    static func trailingBarItemFrame() -> CGRect? {
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
        where window.isKeyWindow {
            guard var top = window.rootViewController else { continue }
            while let presented = top.presentedViewController { top = presented }
            guard let bar = first(UINavigationBar.self, in: top.view) else { continue }
            let items = all(in: bar) { "\(type(of: $0))".hasPrefix("UIKitBarItemHost") && !$0.isHidden }
            let frames = items.map { $0.convert($0.bounds, to: window) }.filter { $0.width > 0 }
            if let trailing = frames.max(by: { $0.midX < $1.midX }) { return trailing }
        }
        return nil
    }

    private static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = first(type, in: subview) { return match } }
        return nil
    }

    private static func all(in view: UIView, where test: (UIView) -> Bool) -> [UIView] {
        (test(view) ? [view] : []) + view.subviews.flatMap { all(in: $0, where: test) }
    }

    private static func label(titled title: String, in view: UIView) -> UILabel? {
        if view.isHidden || view.alpha < 0.01 { return nil }
        if let label = view as? UILabel, label.text == title { return label }
        for subview in view.subviews {
            if let label = label(titled: title, in: subview) { return label }
        }
        return nil
    }
}

/// The page between two parts of the story: what was done, what comes next, on to it or stop there (the rest
/// waits in Settings). (6.4.0, "Plan to Logbook")
struct DryRunPartEndPage: View {
    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession
    let step: DryRunCoachStep

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private let ink = Color(red: 0.106, green: 0.11, blue: 0.125)

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text(step.title)
                    .font(.aero(size: 24, weight: .bold))
                if !step.body.isEmpty {
                    Text(step.body)
                        .font(.aero(size: 17))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    if let next = step.part.next {
                        button(L10n.DryRunCoach.onTo(next.title), filled: true) { coach.next() }
                    }
                    button(L10n.DryRunCoach.stopHere, filled: false) { session.stop() }
                }
                .padding(.top, 4)
                Text(L10n.DryRunCoach.stopHereNote)
                    .font(.aero(size: 14))
                    .opacity(0.7)
            }
            .foregroundColor(ink)
            .padding(22)
            .frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 18).fill(paper))
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.aero(size: 17, weight: .bold))
                .foregroundColor(filled ? paper : ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 11).fill(filled ? ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// The coach's light card, docked above the act band (D4, Q5 A): the chapter and its progress, what to look at
/// or do, and on a look step Pause and Next.
struct DryRunCoachCard: View {
    /// What a ground screen leaves free under its last control in a dry run, for the card at its foot.
    static let room: CGFloat = 240

    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession
    let step: DryRunCoachStep
    let compact: Bool

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private let ink = Color(red: 0.106, green: 0.11, blue: 0.125)

    /// "Fly it · chapter 2 of 7 · Engine and taxi", "Plan a flight"; shorter on a phone.
    private var header: String {
        guard step.part == .fly, step.chapter > 0 else { return step.part.title }
        let chapter = L10n.DryRunCoach.chapterOf(step.chapter, DryRunChapters.count)
        return compact ? chapter : "\(chapter) · \(DryRunChapters.title(step.chapter))"
    }

    var body: some View {
        Group {
            if coach.isFolded { folded } else { card }
        }
        .foregroundColor(ink)
        .background(RoundedRectangle(cornerRadius: 14).fill(paper))
        // How far into its part: a bar along the top edge that fills card by card (the author's second dry run
        // checks: four marks that never moved within a part read as a progress gone wrong).
        .overlay(alignment: .top) {
            if let progress = coach.partProgress {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(ink.opacity(0.6))
                        .frame(width: geometry.size.width * CGFloat(progress.done + 1) / CGFloat(progress.total))
                }
                .frame(height: 3)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                .accessibilityHidden(true)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }

    /// "PART 1 OF 4": which of the story's four parts this is, in words.
    private var partLine: some View {
        Text(L10n.DryRunCoach.partOf(step.part.rawValue, DryRunPart.allCases.count))
            .font(.aero(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .textCase(.uppercase)
            .lineLimit(1)
            .opacity(0.7)
    }

    /// The card folded to one line: what to do, with a verb (its title when it has no such line), and a tap
    /// opens it again.
    private var folded: some View {
        Button { coach.unfold() } label: {
            HStack(spacing: 10) {
                Text(step.foldText(session.world.appState))
                    .font(.aero(size: compact ? 15 : 16, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                partLine
                Image(systemName: "chevron.up")
                    .font(.aero(size: 14, weight: .bold))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title)
        .accessibilityHint(L10n.DryRunCoach.unfold)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(header)
                    .font(.aero(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.7)
                Spacer(minLength: 4)
                partLine
                Button { coach.fold() } label: {
                    Image(systemName: "chevron.down")
                        .font(.aero(size: 14, weight: .bold))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.DryRunCoach.fold)
            }
            Text(step.title)
                .font(.aero(size: compact ? 17 : 19, weight: .bold))
            // Its words scroll where the card has less room than they need (a phone on its side, i-5).
            ViewThatFits(in: .vertical) {
                bodyText
                ScrollView { bodyText }
            }
            // A check whose items the Menu hides: what the card asks for looks different (the author's third
            // round, r3-14: "the app does not seem to display it").
            if step.target == .check, session.world.appState.currentCheckAwaitsConfirmation {
                Text(L10n.DryRunCoach.memoryCheckNote)
                    .font(.aero(size: compact ? 14 : 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if step.kind == .look {
                    // Pause only where a flight runs; on the ground nothing moves.
                    if step.screen == .cockpit {
                        button(session.isPaused ? L10n.DryRunCoach.goOn : L10n.DryRunCoach.pause, filled: false) {
                            session.isPaused ? session.resume() : session.pause()
                        }
                    }
                    button(L10n.DryRunCoach.next, filled: true) { coach.next() }
                } else if step.target != nil {
                    button(L10n.DryRunCoach.showAgain, filled: false) { coach.showAgain() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var bodyText: some View {
        Text(step.text(session.world.appState))
            .font(.aero(size: compact ? 15 : 16))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    let start: DryRunStart
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(start.part == .fly ? L10n.DryRunCoach.coverTitle(start.chapter) : L10n.DryRunCoach.coverTitlePart)
                .font(.aero(size: 15, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundColor(theme.textSecondary)
            Text(start.part == .fly ? DryRunChapters.title(start.chapter) : start.part.title)
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
