import SwiftUI

/// View for confirming detected flight events (go-arounds, touch-and-gos)
struct EventConfirmationView: View {
    let event: DetectedFlightEvent
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var autoDismissTask: Task<Void, Never>?
    @State private var countdownTask: Task<Void, Never>?
    @State private var secondsRemaining: Int = 20

    var body: some View {
        VStack(spacing: 24) {
            // Event icon and type
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 30))
                    .foregroundColor(iconColor)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(iconColor.opacity(0.16)))
                    .accessibilityHidden(true)

                Text(event.type.rawValue)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primaryText)
            }

            // Event details
            VStack(spacing: 8) {
                Text(event.message)
                    .font(.body)
                    .foregroundColor(.primaryText)
                    .multilineTextAlignment(.center)

                if let airport = event.airport {
                    Text(airport.ident)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }

                Text(formattedTime)
                    .font(.caption)
                    .foregroundColor(.dimText)
            }

            // Action buttons
            HStack(spacing: 16) {
                Button(action: {
                    cancelTimers()
                    onDismiss()
                }) {
                    Text(L10n.EventConfirmation.dismiss)
                        .font(.headline)
                        .foregroundColor(.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        )
                }

                Button(action: {
                    cancelTimers()
                    onConfirm()
                }) {
                    Text(L10n.EventConfirmation.confirm)
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(confirmButtonColor))
                }
            }
            .padding(.horizontal)

            // Auto-dismiss countdown + progress (PR-06: unattended events are dismissed, not confirmed)
            VStack(spacing: 6) {
                Text(L10n.EventConfirmation.autoDismiss(secondsRemaining))
                    .font(.caption2)
                    .foregroundColor(.dimText)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(iconColor)
                            .frame(width: geo.size.width * CGFloat(max(0, secondsRemaining)) / 20.0)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 4)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(borderColor, lineWidth: 2)
        )
        .padding(.horizontal, 32)
        .onAppear {
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

    private var iconColor: Color {
        switch event.type {
        case .goAround:
            return .orange
        case .touchAndGo:
            return .blue
        case .fullStop:
            return .aviationAmber
        }
    }

    private var confirmButtonColor: Color {
        switch event.type {
        case .goAround:
            return .orange
        case .touchAndGo:
            return .blue
        case .fullStop:
            return .aviationAmber
        }
    }

    private var borderColor: Color {
        switch event.type {
        case .goAround:
            return .orange.opacity(0.5)
        case .touchAndGo:
            return .blue.opacity(0.5)
        case .fullStop:
            return Color.aviationAmber.opacity(0.5)
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
            try? await Task.sleep(for: .seconds(20))
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

// MARK: - Reusable Overlay

/// The detected-event confirmation overlays (go-around / touch-and-go / full-stop), extracted into
/// one modifier so they can be layered over BOTH the checklist `FlightView` and the full-screen
/// `NavigationMapView`. The map is presented via `.fullScreenCover`, which renders above
/// `FlightView`'s own overlays — so without applying this inside the map too, a detected event's
/// prompt was invisible and undismissable whenever the pilot had the map up. (PR-40)
struct FlightEventConfirmationOverlay: ViewModifier {
    @ObservedObject var flightEventDetector: FlightEventDetector
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .overlay { overlay(for: flightEventDetector.pendingGoAround,
                               record: appState.recordGoAround,
                               dismiss: flightEventDetector.dismissGoAround) }
            .overlay { overlay(for: flightEventDetector.pendingTouchAndGo,
                               record: appState.recordTouchAndGo,
                               dismiss: flightEventDetector.dismissTouchAndGo) }
            .overlay { overlay(for: flightEventDetector.pendingFullStop,
                               record: appState.recordFullStop,
                               dismiss: flightEventDetector.dismissFullStop) }
    }

    @ViewBuilder
    private func overlay(for event: DetectedFlightEvent?,
                         record: @escaping () -> Void,
                         dismiss: @escaping () -> Void) -> some View {
        if let event {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() } // Tap outside dismisses
                // VoiceOver: the two-finger-scrub escape gesture dismisses the dialog. (UX-24)
                .accessibilityAction(.escape) { dismiss() }
            EventConfirmationView(
                event: event,
                onConfirm: { record(); dismiss() },
                onDismiss: { dismiss() }
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
                type: .touchAndGo,
                timestamp: Date(),
                airport: nil,
                message: "Touch-and-go detected"
            ),
            onConfirm: { },
            onDismiss: { }
        )
    }
}
