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
    /// How many are open, when the items themselves can't be listed: the Companion viewer that isn't
    /// entitled to the checklist's text. (v6.0 review, decision 2)
    var openCount: Int? = nil
    /// Stay on the phase, at the first open item.
    let onBack: () -> Void
    /// Leave the phase; the open items become deferred.
    let onContinue: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Deferred.notChecked(openCount ?? items.count))
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
            // On the Cockpit's scale: its label size, and a control's height at least. (v6.0 review)
            .font(.aero(size: CockpitType.label, weight: .semibold))
            .foregroundColor(theme.warning)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: max(56, CockpitTarget.control))
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.warning.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.warning.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Deferred.count(count))
        .accessibilityHint(L10n.Deferred.title)
    }
}

/// Every deferred item, by phase, each with its own CHECK button: the iPad's and the phone's.
struct DeferredItemsSheet: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        DeferredItemsList(
            groups: appState.deferredChecklist.map { group in
                DeferredItemsList.Group(phaseRawValue: group.phase.rawValue, title: group.phase.title,
                                        items: group.items.map { .init(id: $0.id, item: $0) })
            },
            onCheck: { id, phaseRawValue in
                if let phase = ChecklistPhase(rawValue: phaseRawValue) { appState.checkDeferredItem(id, in: phase) }
            },
            onClose: onClose)
    }
}

/// The deferred list itself, from plain values, so the Companion viewer shows the same list from the
/// iPad's snapshot and checks through it. (v6.0 review, decision 2)
struct DeferredItemsList: View {
    struct Row: Identifiable {
        /// The item's id on the device that owns the checklist.
        let id: String
        let item: ChecklistItem
    }

    struct Group: Identifiable {
        let phaseRawValue: Int
        let title: String
        let items: [Row]
        var id: Int { phaseRawValue }
    }

    let groups: [Group]
    let onCheck: (_ id: String, _ phaseRawValue: Int) -> Void
    let onClose: () -> Void

    @Environment(\.cockpitTheme) private var theme

    private var count: Int { groups.reduce(0) { $0 + $1.items.count } }

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
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.title.uppercased())
                                .font(.aero(size: 17, weight: .semibold))
                                .tracking(0.8)
                                .foregroundColor(theme.textSecondary)
                                .padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { row in
                                HStack(spacing: 16) {
                                    DeferredItemText(item: row.item)
                                    Spacer(minLength: 8)
                                    Button {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            onCheck(row.id, group.phaseRawValue)
                                        }
                                    } label: {
                                        Text(L10n.Deferred.check.uppercased())
                                            .font(.aero(size: 20, weight: .heavy))
                                            .foregroundColor(theme.actionText)
                                            .frame(minWidth: 128, minHeight: 76)
                                            .background(RoundedRectangle(cornerRadius: 14).fill(theme.action))
                                    }
                                    .accessibilityLabel("\(L10n.Deferred.check) \(row.item.challenge)")
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
        .onChange(of: count) { _, count in
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
