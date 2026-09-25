import SwiftUI

// MARK: - Deferred checklist items (v6.0 · B2)
//
// NEXT used to leave a phase with items still open without a word: the phase bar turned orange and
// the open items were never shown again. Now NEXT lists them first (`OpenItemsReviewSheet`), and
// whatever the pilot leaves unchecked stays on top of the checklist (`DeferredItemsChip`) until it is
// checked from `DeferredItemsSheet`. The FAA's EFB guidance asks for exactly this: leaving an
// incomplete checklist shows the open items for review, and closing it anyway is an explicit choice.
//
// Sized for a kneeboard: rows at 22 pt, buttons at least 76 pt tall.

/// Shown by NEXT when the phase still has unchecked items.
struct OpenItemsReviewSheet: View {
    let phase: ChecklistPhase
    let items: [ChecklistItem]
    /// Stay on the phase, at the first open item.
    let onBack: () -> Void
    /// Leave the phase; the open items become deferred.
    let onContinue: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Deferred.notChecked(items.count))
                    .font(.aero(size: 30, weight: .bold))
                    .foregroundColor(theme.textPrimary)
                Text(phase.title)
                    .font(.aero(size: 20, weight: .medium))
                    .foregroundColor(theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        DeferredItemText(item: item)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
                    }
                }
            }

            VStack(spacing: 12) {
                // The safe choice is the big, filled one.
                Button(action: onBack) {
                    Text(L10n.Deferred.backToChecklist.uppercased())
                        .font(.aero(size: 22, weight: .heavy))
                        .foregroundColor(theme.actionText)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(RoundedRectangle(cornerRadius: 16).fill(theme.action))
                }
                Button(action: onContinue) {
                    Text(L10n.Deferred.continueLater.uppercased())
                        .font(.aero(size: 20, weight: .bold))
                        .foregroundColor(theme.warning)
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .background(RoundedRectangle(cornerRadius: 16).stroke(theme.warning, lineWidth: 2))
                }
                Text(L10n.Deferred.continueNote)
                    .font(.aero(size: 17))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .background(theme.panel.ignoresSafeArea())
    }
}

/// On top of the checklist while anything is deferred; opens the deferred list.
struct DeferredItemsChip: View {
    let count: Int
    let action: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(L10n.Deferred.count(count))
                Spacer(minLength: 8)
                Text(L10n.Deferred.review)
                Image(systemName: "chevron.right")
            }
            .font(.aero(size: 19, weight: .semibold))
            .foregroundColor(theme.warning)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.warning.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.warning.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Deferred.count(count))
        .accessibilityHint(L10n.Deferred.title)
    }
}

/// Every deferred item, by phase, each with its own CHECK button.
struct DeferredItemsSheet: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Deferred.title)
                    .font(.aero(size: 30, weight: .bold))
                    .foregroundColor(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.Button.done, action: onClose)
                    .font(.aero(size: 20, weight: .semibold))
                    .foregroundColor(theme.action)
                    .frame(minWidth: 64, minHeight: 56)
            }
            Text(L10n.Deferred.hint)
                .font(.aero(size: 17))
                .foregroundColor(theme.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(appState.deferredChecklist, id: \.phase) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.phase.title.uppercased())
                                .font(.aero(size: 17, weight: .semibold))
                                .tracking(0.8)
                                .foregroundColor(theme.textSecondary)
                                .padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in
                                HStack(spacing: 16) {
                                    DeferredItemText(item: item)
                                    Spacer(minLength: 8)
                                    Button {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            appState.checkDeferredItem(item.id, in: group.phase)
                                        }
                                    } label: {
                                        Text(L10n.Deferred.check.uppercased())
                                            .font(.aero(size: 20, weight: .heavy))
                                            .foregroundColor(theme.actionText)
                                            .frame(minWidth: 128, minHeight: 76)
                                            .background(RoundedRectangle(cornerRadius: 14).fill(theme.action))
                                    }
                                    .accessibilityLabel("\(L10n.Deferred.check) \(item.challenge)")
                                }
                                .padding(.vertical, 10)
                                .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
        .background(theme.panel.ignoresSafeArea())
        // The last one checked: nothing left to show.
        .onChange(of: appState.deferredItemCount) { _, count in
            if count == 0 { onClose() }
        }
    }
}

/// Challenge over response, so the eye doesn't cross the screen along a dot leader.
private struct DeferredItemText: View {
    let item: ChecklistItem

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.challenge)
                .font(.aero(size: 22, weight: .semibold))
                .foregroundColor(theme.textPrimary)
            if !item.response.isEmpty {
                Text(item.response)
                    .font(.aero(size: 20))
                    .foregroundColor(theme.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
