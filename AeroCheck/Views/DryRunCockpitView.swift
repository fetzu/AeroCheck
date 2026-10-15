import SwiftUI

// MARK: - Dry run (6.4.0): the Cockpit, in a dry run's world

private struct IsDryRunKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DryRunSessionKey: EnvironmentKey {
    static var defaultValue: DryRunSession? { nil }
}

extension EnvironmentValues {
    /// A dry run's Cockpit: what would reach out of the app from a real flight's (the Companion toggle) it
    /// doesn't offer. (6.4.0)
    var isDryRun: Bool {
        get { self[IsDryRunKey.self] }
        set { self[IsDryRunKey.self] = newValue }
    }

    /// The dry run the Cockpit flies, for its controls in the Menu. (6.4.0)
    var dryRunSession: DryRunSession? {
        get { self[DryRunSessionKey.self] }
        set { self[DryRunSessionKey.self] = newValue }
    }
}

/// The real Cockpit over the app, on the dry run's world: its AppState, GPS, plans, threads, detector, an inert
/// Companion manager and a radio that tells the Watch nothing. The data the app shares with every flight (the
/// airports, the maps, the weather) comes from the app's environment. Over it, the band in place of the status
/// bar (the author's D4 picks, 13 Oct: on the iPad with the controls, 44 pt; on the iPhone around the Dynamic
/// Island, the controls in the Menu) and the card on final. When the flight ends, the dry run's page. The app
/// leaving the foreground pauses it (D2). (6.4.0)
struct DryRunCockpitView: View {
    @ObservedObject var session: DryRunSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.state {
            case .flying:
                cockpit
            case .over(let summary):
                DryRunSummaryView(summary: summary,
                                  onAgain: { Task { await DryRunCenter.shared.again() } },
                                  onDone: { DryRunCenter.shared.end() })
            }
        }
        .statusBarHidden(true)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.pause() }
        }
    }

    private var cockpit: some View {
        let world = session.world
        return GeometryReader { geo in
            let metrics = DryRunBandMetrics(width: geo.size.width, height: geo.size.height,
                                            safeTop: geo.safeAreaInsets.top)
            ZStack(alignment: .top) {
                FlightView(radio: world.radio)
                    .environment(world.appState)
                    .environmentObject(world.location)
                    .environmentObject(world.plans)
                    .environmentObject(world.threads)
                    .environmentObject(world.detector)
                    .environmentObject(world.companion)
                    .environment(\.isDryRun, true)
                    .environment(\.dryRunSession, session)
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: metrics.extraTop) }
                DryRunBand(session: session, metrics: metrics)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                if session.isOnFinal {
                    DryRunFinalCard(session: session, compact: !metrics.isWide)
                        .frame(maxWidth: metrics.finalCardWidth)
                        .padding(.horizontal, 12)
                        .padding(.bottom, metrics.finalCardBottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: metrics.layout == .columns ? .bottomLeading : (metrics.isWide ? .bottomLeading : .bottom))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.isOnFinal)
        }
    }
}

// MARK: - Where it shows

/// Shows the dry run's start sheet and, once the sheet has gone, its Cockpit, over this view, when the center
/// says this view asked (`DryRunCenter.presenter`): the app's root, or a screen over it such as the route
/// editor, whose own cover the root can't present over. (6.4.0)
struct DryRunPresenter: ViewModifier {
    let id: String
    @ObservedObject private var center = DryRunCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { center.presenter == id ? center.startRequest : nil },
                                 set: { if $0 == nil { center.startRequest = nil } }),
                   onDismiss: { center.launchPrepared(from: id) }) { request in
                DryRunStartSheet(route: request.route)
            }
            .fullScreenCover(item: Binding(get: { center.presenter == id ? center.session : nil },
                                           set: { if $0 == nil { center.end() } })) { session in
                DryRunCockpitView(session: session)
            }
    }
}

extension View {
    /// The dry run's start sheet and Cockpit over this view, when it asked (`DryRunPresenter`).
    func dryRunPresenter(_ id: String = DryRunCenter.rootPresenter) -> some View {
        modifier(DryRunPresenter(id: id))
    }
}

// MARK: - The band

/// Where the band sits and how tall it is. The iPad: 44 pt from the top of the screen, in place of the status
/// bar and 20 pt more, for the controls (D4, B). The iPhone in portrait: the status bar's own room, either side
/// of the Dynamic Island, nothing below moving. Elsewhere (a phone on its side, a narrow window): 28 pt.
struct DryRunBandMetrics: Equatable {
    var layout: CockpitLayout
    var safeTop: CGFloat
    var isPad: Bool

    init(width: CGFloat, height: CGFloat, safeTop: CGFloat,
         isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) {
        layout = CockpitLayout.make(width: width, height: height)
        self.safeTop = safeTop
        self.isPad = isPad
    }

    var isWide: Bool { layout == .wide }
    /// A phone upright with the Dynamic Island (or a notch): the band is the room either side of it.
    var hasIsland: Bool { !isPad && layout == .narrow && safeTop >= 44 }
    var height: CGFloat { isWide ? max(44, safeTop) : (hasIsland ? safeTop : max(28, safeTop)) }
    /// What the Cockpit below gives up: nothing on a phone upright.
    var extraTop: CGFloat { max(0, height - safeTop) }
    /// The band holds the controls: the iPad's; the phone's are in the Menu.
    var holdsControls: Bool { isWide }

    /// The act band's room above the safe area's foot, so the card on final sits just over it.
    var actBandHeight: CGFloat {
        let band = ActBandMetrics.make(layout: layout)
        return band.height + (layout == .wide ? 24 : 20)
    }
    var finalCardBottom: CGFloat { layout == .columns ? 12 : actBandHeight + 8 }
    var finalCardWidth: CGFloat { isWide ? 560 : .infinity }
}

/// The hatching that says DRY RUN without a word: the same in every theme, unlike anything else in the app.
struct DryRunHatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.15, green: 0.16, blue: 0.19)))
            var stripes = Path()
            let step: CGFloat = 14
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(stripes, with: .color(Color(red: 0.24, green: 0.25, blue: 0.29)), lineWidth: 7)
        }
        .accessibilityHidden(true)
    }
}

/// "DRY RUN · 4×" on its plate, legible over the hatching.
struct DryRunPlate: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        Text(text)
            .font(.aero(size: size, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.72)))
    }
}

/// The band: DRY RUN and where it stands on every page, and on the iPad the controls.
struct DryRunBand: View {
    @ObservedObject var session: DryRunSession
    let metrics: DryRunBandMetrics
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        ZStack {
            DryRunHatch()
            if metrics.holdsControls {
                HStack(spacing: 10) {
                    DryRunPlate(text: "\(L10n.DryRun.band) · \(state)")
                    Spacer(minLength: 8)
                    DryRunControls(session: session, height: 36)
                }
                .padding(.horizontal, 12)
                .padding(.top, max(0, metrics.height - 44))
            } else if metrics.hasIsland {
                // Either side of the Dynamic Island, on its centre line.
                HStack {
                    DryRunPlate(text: L10n.DryRun.band)
                    Spacer(minLength: 140)
                    DryRunPlate(text: shortState)
                }
                .padding(.horizontal, 22)
                .frame(height: 37)
                .padding(.top, 11)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                DryRunPlate(text: "\(L10n.DryRun.band) · \(state)", size: 11)
            }
        }
        .frame(height: metrics.height)
        .accessibilityElement(children: .contain)
    }

    /// Where it stands: its pace, paused, on to the next check, waiting for the pilot.
    private var state: String {
        if session.isSkipping { return L10n.DryRun.skipping }
        if session.isPaused { return L10n.DryRun.paused }
        if session.isWaiting { return L10n.DryRun.waiting }
        return DryRunSetup.paceLabel(session.rate)
    }

    private var shortState: String {
        if session.isSkipping { return DryRunSetup.paceLabel(DryRunSession.skipRate) }
        if session.isPaused { return L10n.DryRun.paused }
        if session.isWaiting { return L10n.DryRun.waitingShort }
        return DryRunSetup.paceLabel(session.rate)
    }
}

/// Pause, the pace and Next check: in the iPad's band, and in the Menu.
struct DryRunControls: View {
    @ObservedObject var session: DryRunSession
    var height: CGFloat = 36
    /// The pace on one row, Next check under it: the Menu on a phone.
    var stacked = false
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) { pace }
                nextCheck.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 6) {
                pace
                nextCheck
            }
        }
    }

    @ViewBuilder private var pace: some View {
            control(selected: session.isPaused, label: session.isPaused ? L10n.DryRun.resume : L10n.DryRun.pause) {
                session.isPaused ? session.resume() : session.pause()
            } face: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
            }
            ForEach(DryRunSetup.rates, id: \.self) { rate in
                control(selected: !session.isPaused && !session.isSkipping && session.rate == rate,
                        label: L10n.DryRun.paceAccessibility(DryRunSetup.paceLabel(rate))) {
                    session.setRate(rate)
                    session.resume()
                } face: {
                    Text(DryRunSetup.paceLabel(rate))
                }
            }
    }

    private var nextCheck: some View {
        control(selected: session.isSkipping, label: L10n.DryRun.nextCheck, wide: true) {
            session.skipToNextCheck()
        } face: {
            Text("\(L10n.DryRun.nextCheck) ›")
        }
        .disabled(session.isWaiting || session.isSkipping)
    }

    private func control<Face: View>(selected: Bool, label: String, wide: Bool = false, action: @escaping () -> Void,
                                     @ViewBuilder face: () -> Face) -> some View {
        Button(action: action) {
            face()
                .font(.aero(size: 15, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(selected ? theme.actionText : (wide ? theme.action : theme.textPrimary))
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? theme.action : Color.black.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? theme.action : theme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - On final

/// How this final ends: a full stop, a touch-and-go or a go-around, the full stop lit until the pilot picks
/// another. From the start of the final to 250 ft, where the generator takes the choice. (D4, A)
struct DryRunFinalCard: View {
    @ObservedObject var session: DryRunSession
    let compact: Bool
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text(compact ? L10n.DryRun.onThisFinalShort : L10n.DryRun.onThisFinal)
                .font(.aero(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(theme.textSecondary)
            HStack(spacing: 8) {
                choice(.fullStop, L10n.DryRun.fullStop)
                choice(.touchAndGo, L10n.ChecklistAction.touchAndGo)
                choice(.goAround, L10n.ChecklistAction.goAround)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.panelStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }

    private func choice(_ landing: DryRunGenerator.Landing, _ word: String) -> some View {
        let selected = session.finalChoice == landing
        return Button { session.finalChoice = landing } label: {
            Text(word)
                .font(.aero(size: compact ? 14 : 17, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundColor(selected ? theme.actionText : theme.action)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 44 : 52)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? theme.action : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.action, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - The end

/// The dry run's own page when its flight has ended (D4, A): what was flown, that nothing was saved, what to
/// try next, and Fly it again or Done.
struct DryRunSummaryView: View {
    let summary: DryRunSummary
    let onAgain: () -> Void
    let onDone: () -> Void
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack {
                    DryRunHatch()
                    DryRunPlate(text: "\(L10n.DryRun.band) · \(L10n.DryRun.over)")
                        .padding(.top, max(0, geo.safeAreaInsets.top - 30))
                }
                .frame(height: max(44, geo.safeAreaInsets.top))
                .ignoresSafeArea(edges: .top)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("\(summary.title) · \(summary.aircraft)".uppercased())
                            .font(.aero(size: 14, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundColor(theme.textSecondary)
                        Text(L10n.DryRun.overTitle)
                            .font(.aero(size: 34, weight: .bold))
                            .foregroundColor(theme.textPrimary)
                        figures
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                                Text(DryRunSummary.text(of: line))
                            }
                            Text(L10n.DryRun.nothingSaved)
                        }
                        .font(.aero(size: 18))
                        .foregroundColor(theme.textSecondary)
                        Text(summary.nextTime)
                            .font(.aero(size: 18, weight: .semibold))
                            .foregroundColor(theme.textPrimary)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    button(L10n.DryRun.again, filled: false, action: onAgain)
                    button(L10n.DryRun.done, filled: true, action: onDone)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .background(theme.background.ignoresSafeArea())
    }

    private var figures: some View {
        HStack(spacing: 8) {
            figure(L10n.DryRun.checks, "\(summary.checksDone)/\(summary.checksTotal)")
            figure(L10n.DryRun.landings, "\(summary.landings)")
            if summary.wasCircuits {
                figure(L10n.DryRun.circuitsFigure, "\(summary.landings + summary.goArounds)")
            }
            figure(L10n.DryRun.time, DryRunSummary.clock(summary.seconds))
        }
    }

    private func figure(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.aero(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(value)
                .font(.aero(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.panel))
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.aero(size: 19, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(filled ? theme.actionText : theme.action)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 12).fill(filled ? theme.action : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.action, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
