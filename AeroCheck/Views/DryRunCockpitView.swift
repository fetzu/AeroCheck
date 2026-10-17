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
                if let coach = session.coach {
                    DryRunGuidedGate(coach: coach, session: session) { cockpit }
                } else {
                    cockpit
                }
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
                if session.isOnFinal {
                    DryRunFinalCard(session: session, compact: !metrics.isWide)
                        .coachTarget(.finalCard)
                        .frame(maxWidth: metrics.finalCardWidth)
                        .padding(.horizontal, 12)
                        .padding(.bottom, metrics.finalCardBottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: metrics.layout == .columns ? .bottomLeading : (metrics.isWide ? .bottomLeading : .bottom))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.isOnFinal)
            // The guided flight's coach: its card above the act band, the veil and the ring over the control.
            .overlayPreferenceValue(CoachTargetKey.self) { anchors in
                if let coach = session.coach {
                    DryRunCoachLayer(coach: coach, session: session, anchors: anchors, metrics: metrics)
                }
            }
            // The band over everything, the coach's veil included: END is always there to stop the dry run
            // (the author's fifth round, 17 Oct: no graceful way out of it once a card held the Cockpit).
            .overlay(alignment: .top) {
                DryRunBand(session: session, metrics: metrics)
                    .ignoresSafeArea(edges: .top)
            }
            // Paused, said in the middle of the screen with the way on (the author's sixth round, p-9).
            .overlay {
                if session.isPaused { DryRunPausedPlate(session: session) }
            }
            .onPreferenceChange(CockpitPageKey.self) { page in session.coach?.page = page ?? .checklist }
        }
    }
}

/// The guided dry run's screens: the cover while it is taken to where it starts; the Cockpit while its flight
/// runs; the ground (Today, the Logbook) before START FLIGHT and after END FLIGHT.
private struct DryRunGuidedGate<Cockpit: View>: View {
    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession
    @ViewBuilder let cockpit: () -> Cockpit

    var body: some View {
        if coach.isFastForwarding {
            DryRunFastForwardCover(start: coach.start)
        } else if session.world.appState.isFlightActive {
            cockpit()
        } else {
            DryRunGroundView(session: session)
        }
    }
}

/// The ground in the dry run's world (the story's Plan, Close out and Logbook parts): Today and the Logbook, the
/// app's own screens on the world's AppState, plans, flights and GPS, under the band. Plan's other segments,
/// Aircraft and Settings aren't there. No link leaves the app: a card says where it would go, and the coach
/// hears it. (6.4.0, "Plan to Logbook")
struct DryRunGroundView: View {
    @ObservedObject var session: DryRunSession
    /// The link the dry run kept from opening, for its card.
    @State private var keptLink: URL?

    var body: some View {
        let world = session.world
        @Bindable var appState = world.appState
        VStack(spacing: 0) {
            DryRunGroundBand(session: session)
            TabView(selection: $appState.groundTab) {
                HomeView()
                    .dryRunCoachScreen(.today)
                    .tabItem { Label(L10n.Ground.today, systemImage: "sun.horizon.fill") }
                    .tag(GroundTab.today)
                FlightLogView(mode: .logbook)
                    .dryRunCoachScreen(.logbook)
                    .tabItem { Label(L10n.Ground.logbook, systemImage: "book.closed.fill") }
                    .tag(GroundTab.logbook)
            }
            .tint(.aviationGold)
        }
        .background(Color.cockpitBackground.ignoresSafeArea())
        .environment(world.appState)
        .environmentObject(world.location)
        .environmentObject(world.plans)
        .environmentObject(world.threads)
        .environmentObject(world.detector)
        .environmentObject(world.companion)
        .environment(\.isDryRun, true)
        .environment(\.dryRunSession, session)
        .environment(\.openURL, OpenURLAction { url in
            keptLink = url
            session.coach?.noteLink()
            return .handled
        })
        .alert(L10n.DryRunCoach.linkKeptTitle, isPresented: Binding(get: { keptLink != nil },
                                                                     set: { if !$0 { keptLink = nil } })) {
            Button(L10n.Subscription.ok) { keptLink = nil }
        } message: {
            Text(L10n.DryRunCoach.linkKept(keptLink.map(Self.place) ?? ""))
        }
        // Only Today and the Logbook are here: a button that goes to another tab comes back to Today.
        .onChange(of: world.appState.groundTab) { _, tab in
            if tab != .today, tab != .logbook { world.appState.groundTab = .today }
        }
    }

    /// Where a link goes, as a pilot reads it: the site's name, or the number a call would dial.
    static func place(_ url: URL) -> String {
        if url.scheme == "tel" { return url.absoluteString.replacingOccurrences(of: "tel://", with: "") }
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

/// DRY RUN PAUSED in the middle of the screen while the dry run is paused, and the button that goes on.
struct DryRunPausedPlate: View {
    @ObservedObject var session: DryRunSession

    var body: some View {
        VStack(spacing: 14) {
            Text(L10n.DryRun.pausedTitle)
                .font(.aero(size: 22, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
            Button { session.resume() } label: {
                Label(L10n.DryRunCoach.goOn, systemImage: "play.fill")
                    .font(.aero(size: 17, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 48)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.DryRun.resume)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
        .overlay(alignment: .top) {
            DryRunHatch()
                .frame(height: 6)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        }
        .accessibilityElement(children: .contain)
    }
}

/// END, in the band over every screen of a dry run: it stops the dry run and shows its page.
struct DryRunEndButton: View {
    @ObservedObject var session: DryRunSession
    var size: CGFloat = 13

    var body: some View {
        Button { session.stop() } label: {
            DryRunPlate(text: L10n.DryRunCoach.end, size: size)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.85), lineWidth: 1))
                .frame(minWidth: 44, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.DryRun.endDryRun)
    }
}

/// The band over the ground's screens in a dry run: DRY RUN and the part, and End.
struct DryRunGroundBand: View {
    @ObservedObject var session: DryRunSession

    var body: some View {
        ZStack {
            DryRunHatch(bleeds: true)
            HStack(spacing: 10) {
                if let coach = session.coach {
                    DryRunPartPlate(coach: coach)
                } else {
                    DryRunPlate(text: L10n.DryRun.band)
                }
                Spacer(minLength: 8)
                DryRunEndButton(session: session)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 36)
    }
}

/// DRY RUN and the part the coach is in, as it moves on (the step ahead's between two steps).
private struct DryRunPartPlate: View {
    @ObservedObject var coach: DryRunCoach

    var body: some View {
        DryRunPlate(text: "\(L10n.DryRun.band) · \(coach.part.title)")
    }
}

/// The coach's step over the Cockpit: the veil and the ring where its control is, the card above the act band
/// (and above the card on final when it is up).
struct DryRunCoachLayer: View {
    @ObservedObject var coach: DryRunCoach
    @ObservedObject var session: DryRunSession
    let anchors: [DryRunCoachStep.Target: Anchor<CGRect>]
    let metrics: DryRunBandMetrics

    var body: some View {
        GeometryReader { proxy in
            let bottom = metrics.finalCardBottom + (session.isOnFinal ? (metrics.isWide ? 128 : 112) : 0)
            let alignment: Alignment = metrics.isWide || metrics.layout == .columns ? .bottomLeading : .bottom
            // The Cockpit's own steps: a step for the Menu (a sheet over it) shows there, not here as well.
            if let step = coach.step, step.screen == .cockpit {
                // The prompt over the Cockpit has the card (`dryRunCoachCard`): nothing here meanwhile.
                if coach.hourMeter == nil {
                    let target = coach.resolvedTarget(of: step).flatMap { anchors[$0] }.map { proxy[$0] }
                    // What it rings where the card would stand, above the act band (the undo toast at the foot of
                    // CHECKLIST and ROUTE): the card at the top, under the read band, not over it (st-3, r3-12).
                    // Folded, it is one line at the foot, and stays there unless that line is over it (i-5: folded
                    // at the top, it floated mid-screen). Beside it, nothing to move for.
                    let cardTop = proxy.size.height - bottom - (coach.isFolded ? 52 : 200)
                    let cardRight = alignment == .bottomLeading ? 12 + metrics.coachCardWidth : .infinity
                    let atTop = target.map {
                        $0.maxY > cardTop && $0.minY < proxy.size.height - bottom - 4 && $0.minX < cardRight
                    } ?? false
                    // On a phone on its side the read band is in the column: the top of the page instead.
                    let top = metrics.layout == .columns ? metrics.extraTop + 8
                        : anchors[.readBand].map { proxy[$0].maxY + 8 } ?? 120
                    ZStack {
                        DryRunCoachVeil(step: step, target: target, pulse: coach.pulse)
                        DryRunCoachCard(coach: coach, session: session, step: step, compact: !metrics.isWide)
                            .frame(maxWidth: metrics.coachCardWidth)
                            // Never taller than the room it has: its words scroll, its buttons stay on the screen
                            // (i-5: on a phone on its side they went off its foot).
                            .frame(maxHeight: max(120, proxy.size.height - (atTop ? top + 8 : bottom + metrics.extraTop + 8)))
                            .padding(.horizontal, 12)
                            .padding(atTop ? .top : .bottom, atTop ? top : bottom)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: atTop ? (alignment == .bottomLeading ? .topLeading : .top) : alignment)
                            .transition(.opacity)
                    }
                }
            } else if let line = session.foldedLine {
                DryRunFoldedLine(text: line, chapter: coach.upcoming?.chapter, compact: !metrics.isWide)
                    .frame(maxWidth: metrics.coachCardWidth)
                    .padding(.horizontal, 12)
                    .padding(.bottom, bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: coach.step)
    }
}

// MARK: - The map's camera

/// The map's camera in a dry run faster than real time: moved without an animation. At 4× an animated move came
/// with every fix, four a second, each begun before the last had ended, and the map rocked in the circuit's turns
/// (device check g-7, 16 Oct); unanimated, one fix after another reads as a smooth follow at any pace. On the
/// wall clock (every real flight) it animates, as before. (6.4.0)
enum DryRunCameraPace {
    static var animates: Bool { (FlightClock.virtual?.rate ?? 1) <= 1.5 }
}

// MARK: - Where it shows

/// Shows the dry run's start sheet and, once the sheet has gone, its Cockpit, over this view, when the center
/// says this view asked (`DryRunCenter.presenter`): the app's root, or a screen over it such as the route
/// editor, whose own cover the root can't present over. (6.4.0)
struct DryRunPresenter: ViewModifier {
    let id: String
    @ObservedObject private var center = DryRunCenter.shared
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var aircraftDataService: AircraftDataService

    func body(content: Content) -> some View {
        content
            // The guided flight (Today's card, onboarding's last page, Settings): no sheet, it starts at once.
            .onChange(of: center.guidedRequest?.id) { _, request in
                guard request != nil, center.presenter == id, let start = center.guidedRequest?.start else { return }
                center.guidedRequest = nil
                Task {
                    await center.beginGuided(start, settings: { [appState] in appState.settings },
                                             airports: airportDataService, aircraftData: aircraftDataService,
                                             isFlightActive: appState.isFlightActive)
                }
            }
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
    var width: CGFloat

    init(width: CGFloat, height: CGFloat, safeTop: CGFloat,
         isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad) {
        layout = CockpitLayout.make(width: width, height: height)
        self.safeTop = safeTop
        self.isPad = isPad
        self.width = width
    }

    /// The page beside the column on a phone on its side: the cards stay on it, off the column's read band and
    /// act band (the author's seventh round, i-5: over both, the card was sent up out of the way of a control
    /// in the column, and its foot went off the screen).
    var pageWidth: CGFloat { max(260, width - FlightView.cockpitColumnWidth - 24) }
    /// How wide the coach's card and its folded line are.
    var coachCardWidth: CGFloat { isWide ? 600 : (layout == .columns ? pageWidth : .infinity) }

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
    var finalCardWidth: CGFloat { isWide ? 560 : (layout == .columns ? pageWidth : .infinity) }
}

/// The hatching that says DRY RUN without a word: the same in every theme, unlike anything else in the app.
/// A band's (`bleeds`) runs under the side safe areas, across the whole screen of a phone on its side (the
/// author's seventh round, i-5: it stopped short of both edges).
struct DryRunHatch: View {
    var bleeds = false

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
        .ignoresSafeArea(edges: bleeds ? .horizontal : [])
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

/// The band: DRY RUN and where it stands on every page, END, and on the iPad the controls.
struct DryRunBand: View {
    @ObservedObject var session: DryRunSession
    let metrics: DryRunBandMetrics
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        ZStack {
            DryRunHatch(bleeds: true)
            if metrics.holdsControls {
                HStack(spacing: 10) {
                    DryRunPlate(text: "\(L10n.DryRun.band) · \(state)")
                    Spacer(minLength: 8)
                    // The guided flight paces itself: its coach has Pause.
                    if session.coach == nil { DryRunControls(session: session, height: 36) }
                    DryRunEndButton(session: session)
                }
                .padding(.horizontal, 12)
                .padding(.top, max(0, metrics.height - 44))
            } else if metrics.hasIsland {
                // Either side of the Dynamic Island, on its centre line: where it stands, and END.
                HStack {
                    DryRunPlate(text: "\(L10n.DryRun.band) · \(shortState)")
                    Spacer(minLength: 140)
                    DryRunEndButton(session: session)
                }
                .padding(.horizontal, 22)
                .frame(height: 37)
                .padding(.top, 11)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 8) {
                    DryRunPlate(text: "\(L10n.DryRun.band) · \(state)", size: 11)
                    Spacer(minLength: 8)
                    DryRunEndButton(session: session, size: 11)
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: metrics.height)
        .accessibilityElement(children: .contain)
    }

    /// Where it stands: its pace (the guided flight's own as it goes), paused, on to the next check, waiting
    /// for the pilot.
    private var state: String {
        if session.isSkipping { return L10n.DryRun.skipping }
        if session.isPaused { return L10n.DryRun.paused }
        if session.isWaiting { return L10n.DryRun.waiting }
        return DryRunSetup.paceLabel(session.coach == nil ? session.rate : session.pace)
    }

    private var shortState: String {
        if session.isSkipping { return DryRunSetup.paceLabel(DryRunSession.skipRate) }
        if session.isPaused { return L10n.DryRun.paused }
        if session.isWaiting { return L10n.DryRun.waitingShort }
        return DryRunSetup.paceLabel(session.coach == nil ? session.rate : session.pace)
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
/// another. From the start of the final to 250 ft, where the generator takes the choice. (D4, A) Light, as the
/// coach's card, with the band's hatching along its top and a line that says so: the dry run's own control,
/// never in a real flight (the author's fifth round, 17 Oct).
struct DryRunFinalCard: View {
    @ObservedObject var session: DryRunSession
    let compact: Bool

    private let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    private let ink = Color(red: 0.106, green: 0.11, blue: 0.125)

    var body: some View {
        VStack(spacing: 8) {
            Text(compact ? L10n.DryRun.onThisFinalShort : L10n.DryRun.onThisFinal)
                .font(.aero(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .opacity(0.75)
            HStack(spacing: 8) {
                choice(.fullStop, L10n.DryRun.fullStop)
                choice(.touchAndGo, L10n.ChecklistAction.touchAndGo)
                choice(.goAround, L10n.ChecklistAction.goAround)
            }
            Text(L10n.DryRun.finalCardOnly)
                .font(.aero(size: compact ? 12 : 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0.75)
        }
        .foregroundColor(ink)
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(paper))
        .overlay(alignment: .top) {
            DryRunHatch()
                .frame(height: 6)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        }
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
                .foregroundColor(selected ? paper : ink)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 44 : 52)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink, lineWidth: 2))
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
                    DryRunHatch(bleeds: true)
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
                            Text(summary.isStory ? L10n.DryRunCoach.storyNothingKept : L10n.DryRun.nothingSaved)
                        }
                        .font(.aero(size: 18))
                        .foregroundColor(theme.textSecondary)
                        if !summary.habits.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.DryRunCoach.habitsTitle.uppercased())
                                    .font(.aero(size: 13, weight: .semibold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundColor(theme.textSecondary)
                                ForEach(summary.habits, id: \.self) { habit in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "checkmark").foregroundColor(theme.onTarget)
                                        Text(habit)
                                    }
                                }
                            }
                            .font(.aero(size: 18))
                            .foregroundColor(theme.textPrimary)
                        }
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
