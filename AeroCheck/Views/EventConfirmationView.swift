import SwiftUI

/// View for confirming detected flight events (go-arounds, touch-and-gos)
struct EventConfirmationView: View {
    let event: DetectedFlightEvent
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var autoConfirmTask: Task<Void, Never>?
    @State private var countdownTask: Task<Void, Never>?
    @State private var secondsRemaining: Int = 20

    var body: some View {
        VStack(spacing: 24) {
            // Event icon and type
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 48))
                    .foregroundColor(iconColor)

                Text(event.type.rawValue)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }

            // Event details
            VStack(spacing: 8) {
                Text(event.message)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)

                if let airport = event.airport {
                    Text(airport.ident)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }

                Text(formattedTime)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }

            // Action buttons
            HStack(spacing: 16) {
                Button(action: {
                    cancelTimers()
                    onDismiss()
                }) {
                    Text(L10n.EventConfirmation.dismiss)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.gray.opacity(0.4))
                        .cornerRadius(12)
                }

                Button(action: {
                    cancelTimers()
                    onConfirm()
                }) {
                    Text(L10n.EventConfirmation.confirm)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(confirmButtonColor)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)

            // Auto-confirm countdown
            Text(L10n.EventConfirmation.autoConfirm(secondsRemaining))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(borderColor, lineWidth: 2)
        )
        .padding(.horizontal, 32)
        .onAppear {
            startAutoConfirmTimer()
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

    private func startAutoConfirmTimer() {
        autoConfirmTask = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled {
                await MainActor.run {
                    onConfirm()
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
        autoConfirmTask?.cancel()
        countdownTask?.cancel()
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
            onConfirm: { print("Confirmed") },
            onDismiss: { print("Dismissed") }
        )
    }
}
