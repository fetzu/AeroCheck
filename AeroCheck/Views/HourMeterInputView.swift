import SwiftUI

/// Phase for hour meter input - determines the title and context
enum HourMeterPhase {
    case start
    case stop

    var title: String {
        switch self {
        case .start: return L10n.HourMeter.beforeStartTitle
        case .stop: return L10n.HourMeter.afterStopTitle
        }
    }

    var subtitle: String {
        switch self {
        case .start: return L10n.HourMeter.beforeStartSubtitle
        case .stop: return L10n.HourMeter.afterStopSubtitle
        }
    }
}

/// Dial pad view for entering engine hour meter readings
/// ⚠️ Presented via .fullScreenCover in FlightView — DO NOT change presentation style
/// without explicit user request. On iPad this view renders its own centered modal card
/// to match the form-sheet aesthetic while guaranteeing all content is visible.
struct HourMeterInputView: View {
    @Binding var isPresented: Bool
    let phase: HourMeterPhase
    let onSubmit: (Double, String) -> Void // (hours, inputFormat: "decimal" or "time")
    var initialValue: String = ""
    var startHours: Double? = nil // Only used for .stop phase to validate end >= start

    @State private var inputValue: String = ""
    @State private var showInvalidAlert = false
    @State private var showEndBeforeStartAlert = false

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        if isIPad {
            iPadBody
        } else {
            iPhoneBody
        }
    }

    // MARK: - iPhone Layout (full-screen, unchanged from original)

    private var iPhoneBody: some View {
        NavigationView {
            ScrollView {
                dialPadContent
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) {
                        isPresented = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { loadInitialValue() }
        .alert(L10n.HourMeter.invalidFormatTitle, isPresented: $showInvalidAlert) {
            Button(L10n.Subscription.ok, role: .cancel) { }
        } message: {
            Text(L10n.HourMeter.invalidFormatMessage)
        }
        .alert(L10n.HourMeter.endBeforeStartTitle, isPresented: $showEndBeforeStartAlert) {
            Button(L10n.Subscription.ok, role: .cancel) { }
        } message: {
            Text(L10n.HourMeter.endBeforeStartMessage)
        }
    }

    // MARK: - iPad Layout (centered modal card on dimmed background)

    private var iPadBody: some View {
        ZStack {
            // Dimmed background — tap to cancel
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Floating modal card
            VStack(spacing: 0) {
                // Cancel bar
                HStack {
                    Button(L10n.Button.cancel) {
                        isPresented = false
                    }
                    .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Content
                dialPadContent
            }
            .background(Color.cockpitBackground)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            .frame(maxWidth: 540)
            .padding(.horizontal, 40)
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .onAppear { loadInitialValue() }
        .alert(L10n.HourMeter.invalidFormatTitle, isPresented: $showInvalidAlert) {
            Button(L10n.Subscription.ok, role: .cancel) { }
        } message: {
            Text(L10n.HourMeter.invalidFormatMessage)
        }
        .alert(L10n.HourMeter.endBeforeStartTitle, isPresented: $showEndBeforeStartAlert) {
            Button(L10n.Subscription.ok, role: .cancel) { }
        } message: {
            Text(L10n.HourMeter.endBeforeStartMessage)
        }
    }

    // MARK: - Shared Content

    private var dialPadContent: some View {
        VStack(spacing: 20) {
            // Title and subtitle
            VStack(spacing: 8) {
                Text(phase.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primaryText)

                Text(phase.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 16)

            // Display showing current input
            VStack(spacing: 4) {
                Text(inputValue.isEmpty ? "0.0" : inputValue)
                    .font(.system(size: 56, weight: .light, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color.panelBackground)
                    .cornerRadius(12)

                Text(L10n.HourMeter.hours)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
            .padding(.horizontal, 32)

            // Format hint
            Text(L10n.HourMeter.formatHint)
                .font(.caption)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Dial pad
            VStack(spacing: 12) {
                // Row 1: 1, 2, 3
                HStack(spacing: 12) {
                    dialButton("1")
                    dialButton("2")
                    dialButton("3")
                }

                // Row 2: 4, 5, 6
                HStack(spacing: 12) {
                    dialButton("4")
                    dialButton("5")
                    dialButton("6")
                }

                // Row 3: 7, 8, 9
                HStack(spacing: 12) {
                    dialButton("7")
                    dialButton("8")
                    dialButton("9")
                }

                // Row 4: ., 0, :
                HStack(spacing: 12) {
                    dialButton(".")
                    dialButton("0")
                    dialButton(":")
                }
            }
            .padding(.horizontal, 48)

            // Action buttons
            HStack(spacing: 12) {
                // Backspace
                Button(action: backspace) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .foregroundColor(.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.panelBackground)
                        .cornerRadius(10)
                }

                // Clear
                Button(action: { inputValue = "" }) {
                    Text(L10n.HourMeter.clear)
                        .font(.headline)
                        .foregroundColor(.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.panelBackground)
                        .cornerRadius(10)
                }

                // Skip
                Button(action: { isPresented = false }) {
                    Text(L10n.HourMeter.skip)
                        .font(.headline)
                        .foregroundColor(.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.panelBackground)
                        .cornerRadius(10)
                }

                // Save
                Button(action: saveValue) {
                    Text(L10n.HourMeter.save)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(inputValue.isEmpty ? Color.gray : Color.aviationGreen)
                        .cornerRadius(10)
                }
                .disabled(inputValue.isEmpty)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Dial Pad Button

    private func dialButton(_ character: String) -> some View {
        Button(action: { appendCharacter(character) }) {
            Text(character)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.panelBackground)
                .cornerRadius(10)
        }
    }

    // MARK: - Input Logic

    private func loadInitialValue() {
        if !initialValue.isEmpty {
            inputValue = initialValue
        }
    }

    private func appendCharacter(_ character: String) {
        // Prevent multiple decimal points or colons
        if character == "." && inputValue.contains(".") { return }
        if character == ":" && inputValue.contains(":") { return }
        // Prevent both decimal and colon
        if character == "." && inputValue.contains(":") { return }
        if character == ":" && inputValue.contains(".") { return }

        // Limit length to reasonable hour meter reading (e.g., 99999.9)
        if inputValue.count >= 8 { return }

        // For time format, limit minutes to 2 digits
        if inputValue.contains(":") {
            let parts = inputValue.split(separator: ":")
            if parts.count > 1 && parts[1].count >= 2 && character != ":" {
                return
            }
        }

        inputValue += character
    }

    private func backspace() {
        if !inputValue.isEmpty {
            inputValue.removeLast()
        }
    }

    private func saveValue() {
        guard let hours = parseInput() else {
            showInvalidAlert = true
            return
        }
        // Validate that end hours >= start hours
        if phase == .stop, let start = startHours, hours < start {
            showEndBeforeStartAlert = true
            return
        }
        let format = inputValue.contains(":") ? "time" : "decimal"
        onSubmit(hours, format)
        isPresented = false
    }

    /// Parse the input string to hours
    /// Supports: "1234.5" (decimal) or "1234:30" (time format where :30 = 0.5 hours)
    private func parseInput() -> Double? {
        let trimmed = inputValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Time format (1234:30)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 2,
                  let wholePart = Double(parts[0]),
                  let minutesPart = Double(parts[1]) else {
                return nil
            }
            // Convert minutes to decimal hours (60 min = 1 hour)
            let decimalMinutes = minutesPart / 60.0
            return wholePart + decimalMinutes
        }

        // Decimal format (1234.5)
        return Double(trimmed)
    }
}

// MARK: - Preview

#Preview {
    HourMeterInputView(
        isPresented: .constant(true),
        phase: .start,
        onSubmit: { hours, format in
            print("Submitted: \(hours) hours (format: \(format))")
        }
    )
}
