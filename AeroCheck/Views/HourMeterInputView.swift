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
struct HourMeterInputView: View {
    @Binding var isPresented: Bool
    let phase: HourMeterPhase
    let onSubmit: (Double, String) -> Void // (hours, inputFormat: "decimal" or "time")
    var initialValue: String = ""

    @State private var inputValue: String = ""
    @State private var showInvalidAlert = false

    var body: some View {
        NavigationView {
            ScrollView {
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
                    HStack(spacing: 16) {
                        // Backspace
                        Button(action: backspace) {
                            Image(systemName: "delete.left")
                                .font(.title2)
                                .foregroundColor(.secondaryText)
                                .frame(width: 60, height: 50)
                                .background(Color.panelBackground)
                                .cornerRadius(10)
                        }

                        // Clear
                        Button(action: { inputValue = "" }) {
                            Text(L10n.HourMeter.clear)
                                .font(.headline)
                                .foregroundColor(.secondaryText)
                                .frame(width: 80, height: 50)
                                .background(Color.panelBackground)
                                .cornerRadius(10)
                        }

                        Spacer()

                        // Skip
                        Button(action: { isPresented = false }) {
                            Text(L10n.HourMeter.skip)
                                .font(.headline)
                                .foregroundColor(.secondaryText)
                                .frame(width: 80, height: 50)
                                .background(Color.panelBackground)
                                .cornerRadius(10)
                        }

                        // Save
                        Button(action: saveValue) {
                            Text(L10n.HourMeter.save)
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 100, height: 50)
                                .background(inputValue.isEmpty ? Color.gray : Color.aviationGreen)
                                .cornerRadius(10)
                        }
                        .disabled(inputValue.isEmpty)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
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
        .onAppear {
            if !initialValue.isEmpty {
                inputValue = initialValue
            }
        }
        .alert(L10n.HourMeter.invalidFormatTitle, isPresented: $showInvalidAlert) {
            Button(L10n.Subscription.ok, role: .cancel) { }
        } message: {
            Text(L10n.HourMeter.invalidFormatMessage)
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
