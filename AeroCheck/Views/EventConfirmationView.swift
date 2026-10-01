import SwiftUI

/// The card that asks the pilot to confirm a detected flight event (go-around, touch-and-go,
/// full stop). It sits over the Cockpit, so it is sized like the Cockpit (6.1.0): text in the
/// in-flight type scale, 20 pt at the least on the iPad, and the answers as thumb-bar buttons,
/// 104 pt on the kneeboard (92 on the phone), in the in-flight colours.
struct EventConfirmationView: View {
    let event: DetectedFlightEvent
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @Environment(\.cockpitTheme) private var theme
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var countdownTask: Task<Void, Never>?
    @State private var secondsRemaining: Int = Self.autoDismissSeconds

    /// How long a card that goes by itself stays up.
    static let autoDismissSeconds = 20

    /// Whether the card goes by itself. A go-around or touch-and-go card comes up in the climb-out,
    /// where it must not cover the Cockpit for long: dismissed after 20 s, never confirmed (PR-06).
    /// The full-stop card comes up on the ground, while the pilot vacates the runway and talks on
    /// the radio: it waits for an answer (6.1.0). The detector takes it away at the next take-off.
    static func dismissesByItself(_ type: FlightEventType) -> Bool {
        type != .fullStop
    }

    var body: some View {
        VStack(spacing: CockpitType.size(kneeboard: 24, phone: 18)) {
            // Event icon and type
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.aero(size: CockpitType.button, weight: .bold))
                    .foregroundColor(iconColor)
                    .frame(width: CockpitTarget.control, height: CockpitTarget.control)
                    .background(Circle().fill(iconColor.opacity(0.16)))
                    .accessibilityHidden(true)

                Text(event.type.rawValue)
                    .font(.aero(size: CockpitType.button, weight: .bold))
                    .foregroundColor(theme.textPrimary)
            }

            // Event details
            VStack(spacing: 8) {
                Text(event.message)
                    .font(.aero(size: CockpitType.row, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let airport = event.airport {
                    Text(airport.ident)
                        .font(.aero(size: CockpitType.label, weight: .semibold))
                        .foregroundColor(theme.textSecondary)
                }

                Text(formattedTime)
                    .font(.aero(size: CockpitType.label, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }

            // The answers, as the Cockpit's thumb bar draws them: cyan, the colour of what can be
            // touched; CONFIRM filled, the one that records something.
            HStack(spacing: CockpitType.size(kneeboard: 16, phone: 12)) {
                CockpitThumbButton(title: L10n.EventConfirmation.dismiss, style: .outlined(tint: theme.action)) {
                    cancelTimers()
                    onDismiss()
                }
                CockpitThumbButton(title: L10n.EventConfirmation.confirm,
                                   style: .filled(fill: theme.action, text: theme.actionText)) {
                    cancelTimers()
                    onConfirm()
                }
            }

            // Auto-dismiss countdown + progress (PR-06: unattended events are dismissed, not confirmed)
            if Self.dismissesByItself(event.type) {
                VStack(spacing: 6) {
                    Text(L10n.EventConfirmation.autoDismiss(secondsRemaining))
                        .font(.aero(size: CockpitType.label))
                        .foregroundColor(theme.textDim)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.glassFill)
                            Capsule().fill(iconColor)
                                .frame(width: geo.size.width * CGFloat(max(0, secondsRemaining))
                                       / CGFloat(Self.autoDismissSeconds))
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(CockpitType.size(kneeboard: 28, phone: 20))
        .frame(maxWidth: 720)
        .background(RoundedRectangle(cornerRadius: 24).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.panelStroke, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .padding(.horizontal, CockpitType.size(kneeboard: 24, phone: 16))
        .onAppear {
            guard Self.dismissesByItself(event.type) else { return }
            startAutoDismissTimer()
            startCountdown()
        }
        .onDisappear {
            cancelTimers()
        }
    }

    // MARK: - Computed Properties

    private var iconName: String {
        switch event.type {
        case .goAround:
            return "arrow.up.right.circle.fill"
        case .touchAndGo:
            return "arrow.down.forward.and.arrow.up.backward.circle.fill"
        case .fullStop:
            return "stop.circle.fill"
        }
    }

    /// Only the icon is coloured, by the in-flight contract: a go-around is a caution (amber),
    /// a touch-and-go keeps its blue, a full stop is the normal end of a flight (green).
    private var iconColor: Color {
        switch event.type {
        case .goAround:
            return theme.warning
        case .touchAndGo:
            return theme.info
        case .fullStop:
            return theme.onTarget
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: event.timestamp)
    }

    // MARK: - Timers

    /// PR-06: when the pilot takes no action within the window, default to DISMISS — never
    /// auto-confirm. Auto-confirming committed a possibly-wrong detected event to the logbook and
    /// (via record*) yanked the checklist to another phase hands-off, exactly during the highest-
    /// workload moments. Dismissing discards the unconfirmed event; the pilot can still record it
    /// manually if it was real.
    private func startAutoDismissTimer() {
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
            if !Task.isCancelled {
                await MainActor.run {
                    onDismiss()
                }
            }
        }
    }

    private func startCountdown() {
        countdownTask = Task {
            while !Task.isCancelled && secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled {
                    await MainActor.run {
                        secondsRemaining -= 1
                    }
                }
            }
        }
    }

    private func cancelTimers() {
        autoDismissTask?.cancel()
        countdownTask?.cancel()
    }
}

// MARK: - The landed card (6.1, M4)

/// After a full-stop landing on a flight that isn't circuits, once slow for 10 s: one question, two 104 pt
/// answers. "YES, IT WAS DONE" records the landing check confirmed after landing (a green outline on the
/// phase bar, never solid green); "NOT SURE" records it for the debrief. Either way the after landing check
/// comes next. It replaces the detector's "Full stop" card there (circuits keep theirs), waits for an answer
/// and never times out; a tap beside it is not an answer. A landing check done before touchdown needs no
/// question: the card only takes the pilot on.
///
/// Drawn from values, so the Companion iPhone shows the same card from its snapshot.
struct LandedCardView: View {
    let aerodrome: String?
    /// The touchdown, as the Cockpit writes times (local or UTC, the pilot's setting).
    let time: String
    /// The landing check was done before touchdown (or has nothing to do): nothing to ask.
    let landingCheckSettled: Bool
    let onAnswer: (LandedAnswer) -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let phone = CockpitScale.current == .phone
        VStack(spacing: CockpitType.size(kneeboard: 22, phone: 16)) {
            VStack(spacing: 10) {
                Image(systemName: "airplane.arrival")
                    .font(.aero(size: CockpitType.button, weight: .bold))
                    .foregroundColor(theme.onTarget)
                    .frame(width: CockpitTarget.control, height: CockpitTarget.control)
                    .background(Circle().fill(theme.onTarget.opacity(0.16)))
                    .accessibilityHidden(true)
                Text(L10n.LandedCard.title(aerodrome: aerodrome, time: time))
                    .font(.aero(size: CockpitType.button, weight: .bold))
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(landingCheckSettled ? L10n.LandedCard.landingCheckDone : L10n.LandedCard.question)
                    .font(.aero(size: CockpitType.row, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if landingCheckSettled {
                CockpitThumbButton(title: L10n.Cockpit.next(ChecklistPhase.afterLanding.shortTitle), icon: "chevron.right",
                                   style: .filled(fill: theme.action, text: theme.actionText)) { onAnswer(.next) }
            } else {
                // Side by side on the kneeboard; one over the other on the phone, so neither label shrinks.
                let layout = phone ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
                layout {
                    CockpitThumbButton(title: L10n.LandedCard.yes, icon: phone ? nil : "checkmark",
                                       style: .filled(fill: theme.action, text: theme.actionText)) { onAnswer(.yes) }
                        .accessibilityHint(L10n.LandedCard.yesHint)
                    CockpitThumbButton(title: L10n.LandedCard.notSure,
                                       style: .outlined(tint: theme.action)) { onAnswer(.notSure) }
                        .accessibilityHint(L10n.LandedCard.notSureHint)
                }
                Text(L10n.LandedCard.explanation)
                    .font(.aero(size: CockpitType.label))
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(CockpitType.size(kneeboard: 28, phone: 20))
        .frame(maxWidth: 720)
        .background(RoundedRectangle(cornerRadius: 24).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.panelStroke, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .padding(.horizontal, CockpitType.size(kneeboard: 24, phone: 16))
        .accessibilityElement(children: .contain)
    }
}

/// The landed card over the Cockpit, from `AppState`: the dimmed backdrop ignores taps (a knee or a
/// sleeve on a kneeboard is not an answer), VoiceOver's escape leaves it up (it asks, it doesn't dismiss).
struct LandedCardOverlay: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let card = appState.landedCard {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                LandedCardView(aerodrome: card.aerodrome, time: appState.formatTime(card.touchdown),
                               landingCheckSettled: appState.landingCheckSettled) { appState.answerLandedCard($0) }
            }
        }
    }
}

// MARK: - Reusable Overlay

/// The detected-event confirmation overlays (go-around / touch-and-go / full-stop), extracted into
/// one modifier so they can be layered over BOTH the checklist `FlightView` and the full-screen
/// `NavigationMapView`. The map is presented via `.fullScreenCover`, which renders above
/// `FlightView`'s own overlays — so without applying this inside the map too, a detected event's
/// prompt was invisible and undismissable whenever the pilot had the map up. (PR-40)
struct FlightEventConfirmationOverlay: ViewModifier {
    @ObservedObject var flightEventDetector: FlightEventDetector
    var appState: AppState

    func body(content: Content) -> some View {
        content
            .overlay { overlay(for: flightEventDetector.pendingGoAround) }
            .overlay { overlay(for: flightEventDetector.pendingTouchAndGo) }
            .overlay { overlay(for: flightEventDetector.pendingFullStop) }
            // The landed card (6.1): the full stop on a flight that isn't circuits.
            .overlay { LandedCardOverlay() }
            .onAppear { Self.handOver(flightEventDetector.pendingFullStop, appState: appState, detector: flightEventDetector) }
            .onChange(of: flightEventDetector.pendingFullStop?.id) {
                Self.handOver(flightEventDetector.pendingFullStop, appState: appState, detector: flightEventDetector)
            }
    }

    /// A full stop on a flight that isn't circuits is the landed card's (6.1): the detector's card goes and
    /// the card takes the touchdown. LocationManager hands it over as the detector emits it; this catches
    /// one raised any other way (a scene, a test). Circuits keep the full-stop card and its stop-and-go.
    @MainActor
    static func handOver(_ event: DetectedFlightEvent?, appState: AppState, detector: FlightEventDetector) {
        if appState.takeFullStopForLandedCard(event) { detector.dismissFullStop() }
    }

    /// CONFIRM: the event recorded at its PHYSICAL timestamp (touchdown / approach low point), not
    /// the confirmation tap's wall time, then the card goes. Static so the tests run exactly what the
    /// card runs. (6.1.0)
    @MainActor
    static func confirm(_ event: DetectedFlightEvent, appState: AppState, detector: FlightEventDetector) {
        switch event.type {
        case .goAround: appState.recordGoAround(at: event.timestamp)
        case .touchAndGo: appState.recordTouchAndGo(at: event.timestamp)
        case .fullStop: appState.recordFullStop(at: event.timestamp)
        }
        dismiss(event.type, detector: detector)
    }

    /// DISMISS: the card goes and nothing is recorded; the pilot can still record the event by hand.
    @MainActor
    static func dismiss(_ type: FlightEventType, detector: FlightEventDetector) {
        switch type {
        case .goAround: detector.dismissGoAround()
        case .touchAndGo: detector.dismissTouchAndGo()
        case .fullStop: detector.dismissFullStop()
        }
    }

    @ViewBuilder
    private func overlay(for event: DetectedFlightEvent?) -> some View {
        if let event, !(event.type == .fullStop && appState.isFlightActive && !appState.isCircuitMode) {
            let dismiss = { Self.dismiss(event.type, detector: flightEventDetector) }
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                // A tap outside dismisses a card that goes by itself anyway. One that waits is answered
                // with its buttons only: on a kneeboard, a knee or a sleeve on the backdrop is not an
                // answer. (6.1.0)
                .onTapGesture {
                    if EventConfirmationView.dismissesByItself(event.type) { dismiss() }
                }
                // VoiceOver: the two-finger-scrub escape gesture dismisses the dialog. (UX-24)
                .accessibilityAction(.escape) { dismiss() }
            EventConfirmationView(
                event: event,
                onConfirm: { Self.confirm(event, appState: appState, detector: flightEventDetector) },
                onDismiss: dismiss
            )
        }
    }
}

extension View {
    /// Layers the flight-event confirmation prompts over this view. Applied to both `FlightView`
    /// and `NavigationMapView` so the prompt is always visible/dismissable. (PR-40)
    func flightEventConfirmationOverlay(detector: FlightEventDetector, appState: AppState) -> some View {
        modifier(FlightEventConfirmationOverlay(flightEventDetector: detector, appState: appState))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        EventConfirmationView(
            event: DetectedFlightEvent(
                type: .fullStop,
                timestamp: Date(),
                airport: nil,
                message: "Full-stop landing detected"
            ),
            onConfirm: { },
            onDismiss: { }
        )
    }
}
