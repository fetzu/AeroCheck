import SwiftUI

/// View for confirming detected flight events (go-arounds, touch-and-gos)
struct EventConfirmationView: View {
    let event: DetectedFlightEvent
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var autoDismissTask: Task<Void, Never>?

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
                    autoDismissTask?.cancel()
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
                    autoDismissTask?.cancel()
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

            // Auto-dismiss note
            Text(L10n.EventConfirmation.autoDismiss)
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
            startAutoDismissTimer()
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }

    // MARK: - Computed Properties

    private var iconName: String {
        switch event.type {
        case .goAround:
            return "arrow.up.right.circle.fill"
        case .touchAndGo:
            return "arrow.down.forward.and.arrow.up.backward.circle.fill"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case .goAround:
            return .orange
        case .touchAndGo:
            return .blue
        }
    }

    private var confirmButtonColor: Color {
        switch event.type {
        case .goAround:
            return .orange
        case .touchAndGo:
            return .blue
        }
    }

    private var borderColor: Color {
        switch event.type {
        case .goAround:
            return .orange.opacity(0.5)
        case .touchAndGo:
            return .blue.opacity(0.5)
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: event.timestamp)
    }

    // MARK: - Auto Dismiss

    private func startAutoDismissTimer() {
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                await MainActor.run {
                    onDismiss()
                }
            }
        }
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
