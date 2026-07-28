import SwiftUI

/// On-map hazard indicator, and the list behind it.
///
/// SIGMETs are en-route hazards, so unlike the briefing wind they belong on the map rather than in a
/// briefing sheet. Both views render NOTHING when no hazard is in range — the common case, and an
/// always-present control is one a pilot stops reading.
///
/// Deliberately not a full weather briefing: SIGMET is one hazard class, with no AIRMET, no NOTAM
/// and no DABS behind it. The sheet says so rather than letting the absence imply all-clear.

/// Compact chip shown on the navigation map when a hazard is within range.
struct SigmetChip: View {
    @Environment(\.cockpitTheme) private var theme
    let hazards: [AviationWeatherService.Sigmet]
    let action: () -> Void

    /// Containment is the distinction that matters: a hazard you are inside is a different message
    /// from one 90 nm away, and colour is the fastest way to carry it — reinforced by the wording,
    /// never by colour alone.
    private var isOverhead: Bool { hazards.contains { $0.containsPoint } }

    private var headline: AviationWeatherService.Sigmet? {
        hazards.first { $0.containsPoint } ?? hazards.first
    }

    var body: some View {
        if let headline {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                    Text(SigmetFormat.summary(headline))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if hazards.count > 1 {
                        Text("+\(hazards.count - 1)")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.8)
                    }
                }
                .foregroundColor(isOverhead ? theme.warning : theme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(theme.panel.opacity(0.92))
                        .overlay(
                            Capsule().strokeBorder(
                                isOverhead ? theme.warning : theme.panelStroke,
                                lineWidth: isOverhead ? 1 : 0.5
                            )
                        )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.Nav.sigmetAccessibility(hazards.count)))
            .accessibilityHint(Text(L10n.Nav.sigmetHint))
        }
    }
}

/// The hazard list, ordered nearest first.
struct SigmetSheet: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let hazards: [AviationWeatherService.Sigmet]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(hazards) { hazard in
                        row(hazard)
                    }

                    // The absence of a SIGMET is not an all-clear, and this is the surface most
                    // likely to be mistaken for a briefing tool.
                    Text(L10n.Nav.sigmetDisclaimer)
                        .font(.system(size: 11))
                        .italic()
                        .foregroundColor(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("SIGMET")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
    }

    private func row(_ hazard: AviationWeatherService.Sigmet) -> some View {
        // A leading rule rather than a filled card: the list can be long, and a stack of filled
        // warning cards reads as panic regardless of how far away any of them is.
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(hazard.containsPoint ? theme.warning : theme.panelStroke)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(SigmetFormat.hazardName(hazard))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    Text(SigmetFormat.proximity(hazard))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(hazard.containsPoint ? theme.warning : theme.textDim)
                }
                Text(SigmetFormat.detail(hazard))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Formatting kept out of the views so it can be read — and corrected — in one place.
enum SigmetFormat {

    /// `"SEV TURB"`, or just the hazard when unqualified.
    static func summary(_ hazard: AviationWeatherService.Sigmet) -> String {
        [hazard.qualifier, hazard.hazard].compactMap { $0 }.joined(separator: " ")
    }

    static func hazardName(_ hazard: AviationWeatherService.Sigmet) -> String {
        let text = summary(hazard)
        return text.isEmpty ? L10n.Nav.sigmetUnknownHazard : text
    }

    /// `"overhead"` when the polygon contains the aircraft — never `"0 nm"`, which reads as a
    /// rounding artefact rather than as "you are in it".
    static func proximity(_ hazard: AviationWeatherService.Sigmet) -> String {
        hazard.containsPoint
            ? "· \(L10n.Nav.sigmetOverhead)"
            : String(format: "· %.0f nm", hazard.distanceNm)
    }

    /// `"LSAS SWITZERLAND · SFC-15000 ft · until 0600Z"`.
    static func detail(_ hazard: AviationWeatherService.Sigmet) -> String {
        var parts: [String] = []
        if let fir = [hazard.firId, hazard.firName].compactMap({ $0 }).first {
            parts.append(fir)
        }
        if let band = altitudeBand(hazard) { parts.append(band) }
        if let validTo = hazard.validTo {
            let formatter = DateFormatter()
            formatter.dateFormat = "HHmm"
            formatter.timeZone = TimeZone(identifier: "UTC")
            parts.append("\(L10n.Nav.sigmetUntil) \(formatter.string(from: validTo))Z")
        }
        return parts.joined(separator: " · ")
    }

    /// A base of 0 means the surface, which is what a pilot needs to see — writing "0 ft" would be
    /// technically true and read as a missing value.
    static func altitudeBand(_ hazard: AviationWeatherService.Sigmet) -> String? {
        switch (hazard.baseFt, hazard.topFt) {
        case let (base?, top?):
            return "\(base <= 0 ? "SFC" : "\(base)")-\(top) ft"
        case let (nil, top?):
            return "≤\(top) ft"
        case let (base?, nil):
            return "\(base <= 0 ? "SFC" : "\(base) ft")+"
        default:
            return nil
        }
    }
}
