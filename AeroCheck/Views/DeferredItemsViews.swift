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
    /// Checks deferred whole. (v6.0 review, J1)
    var checks: Int = 0
    let count: Int
    let action: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(L10n.Deferred.summary(checks: checks, items: count))
                    .lineLimit(1).minimumScaleFactor(0.7)
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
        .accessibilityLabel(L10n.Deferred.summary(checks: checks, items: count))
        .accessibilityHint(L10n.Deferred.title)
    }
}

/// Every deferred check with RUN, then every deferred item, by phase, each with its own CHECK button:
/// the iPad's and the phone's. RUN turns the sheet into that check's list. (v6.0 review, J1)
struct DeferredItemsSheet: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @State private var running: ChecklistPhase?

    var body: some View {
        content
            // The last check run to its end, or the last item checked: nothing left to show.
            .onChange(of: appState.hasDeferredWork) { _, owed in
                if !owed { onClose() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let running, appState.deferredChecks.contains(running) {
            let items = appState.checkItems(running)
            DeferredCheckRunView(
                title: running.title,
                backTitle: appState.currentPhase.shortTitle,
                rows: items.map { .init(id: $0.id, item: $0) },
                highlightedIndex: appState.getHighlightedItem(for: running),
                deferredIds: Set(appState.deferredItems[running] ?? []),
                onCheck: { appState.checkItem(inDeferredCheck: running) },
                onDefer: { appState.deferItem(inDeferredCheck: running) },
                onBack: { self.running = nil })
        } else {
            DeferredItemsList(
                checks: appState.deferredCheckList.map {
                    .init(phaseRawValue: $0.phase.rawValue, title: $0.phase.title, remaining: $0.remaining, total: $0.total)
                },
                groups: appState.deferredChecklist.map { group in
                    DeferredItemsList.Group(phaseRawValue: group.phase.rawValue, title: group.phase.title,
                                            items: group.items.map { .init(id: $0.id, item: $0) })
                },
                onRun: { raw in running = ChecklistPhase(rawValue: raw) },
                onCheck: { id, phaseRawValue in
                    if let phase = ChecklistPhase(rawValue: phaseRawValue) { appState.checkDeferredItem(id, in: phase) }
                },
                onClose: onClose)
        }
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

    /// A check deferred whole, and how much of it is left to run. (v6.0 review, J1)
    struct CheckRow: Identifiable {
        let phaseRawValue: Int
        let title: String
        let remaining: Int
        let total: Int
        var id: Int { phaseRawValue }
    }

    var checks: [CheckRow] = []
    let groups: [Group]
    var onRun: (_ phaseRawValue: Int) -> Void = { _ in }
    let onCheck: (_ id: String, _ phaseRawValue: Int) -> Void
    let onClose: () -> Void

    @Environment(\.cockpitTheme) private var theme

    private var count: Int { checks.count + groups.reduce(0) { $0 + $1.items.count } }

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
                    if !checks.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.Deferred.checksHeader.uppercased())
                                .font(.aero(size: 17, weight: .semibold))
                                .tracking(0.8)
                                .foregroundColor(theme.textSecondary)
                                .padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(checks) { check in
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(check.title)
                                            .font(.aero(size: 22, weight: .semibold))
                                            .foregroundColor(theme.textPrimary)
                                        Text(L10n.Deferred.checkRemaining(check.remaining, check.total))
                                            .font(.aero(size: 20))
                                            .foregroundColor(theme.textSecondary)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityElement(children: .combine)
                                    Spacer(minLength: 8)
                                    Button { onRun(check.phaseRawValue) } label: {
                                        Text(L10n.Deferred.run.uppercased())
                                            .font(.aero(size: 20, weight: .heavy))
                                            .foregroundColor(theme.actionText)
                                            .frame(minWidth: 128, minHeight: 76)
                                            .background(RoundedRectangle(cornerRadius: 14).fill(theme.action))
                                    }
                                    .accessibilityLabel("\(L10n.Deferred.run) \(check.title)")
                                }
                                .padding(.vertical, 10)
                                .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
                            }
                        }
                    }
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

// MARK: - Running a deferred check (v6.0 review, J1)

/// A check deferred whole, run from the deferred list: its own list and thumb bar, labelled as a
/// deferred check, over the phase being flown (which stays current). From plain values, so the
/// Companion runs one the same way from the iPad's snapshot.
struct DeferredCheckRunView: View {
    let title: String
    /// The phase being flown, to go back to.
    let backTitle: String
    let rows: [DeferredItemsList.Row]
    let highlightedIndex: Int
    let deferredIds: Set<String>
    let onCheck: () -> Void
    let onDefer: () -> Void
    let onBack: () -> Void

    @Environment(\.cockpitTheme) private var theme

    private var current: ChecklistItem? {
        rows.indices.contains(highlightedIndex) ? rows[highlightedIndex].item : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Button(action: onBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text(backTitle)
                        }
                        .font(.aero(size: CockpitType.label, weight: .semibold))
                        .foregroundColor(theme.action)
                        .padding(.horizontal, 14)
                        .frame(minHeight: CockpitTarget.control)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.action, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Text(L10n.Deferred.runLabel.uppercased())
                        .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(theme.warning)
                }
                Text(title)
                    .font(.aero(size: 30, weight: .bold))
                    .foregroundColor(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Group {
                                if index == highlightedIndex {
                                    CockpitHeroChecklistItem(challenge: row.item.challenge, response: row.item.response,
                                                             progressText: "\(index + 1) / \(rows.count)",
                                                             showAdvanceHint: false)
                                        .padding(.vertical, 4)
                                } else {
                                    let isDeferred = index < highlightedIndex && deferredIds.contains(row.id)
                                    ChecklistItemRow(item: row.item, showSeparator: index < rows.count - 1,
                                                     isCompleted: index < highlightedIndex && !isDeferred,
                                                     isDeferred: isDeferred)
                                }
                            }
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear { proxy.scrollTo(highlightedIndex, anchor: UnitPoint(x: 0.5, y: 0.15)) }
                .onChange(of: highlightedIndex) { _, index in
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.15))
                }
            }

            HStack(spacing: 12) {
                CockpitThumbButton(title: L10n.Cockpit.deferItem, subtitle: L10n.Cockpit.deferHint,
                                   style: .outlined(tint: theme.warning), action: onDefer)
                    .frame(maxWidth: CockpitType.size(kneeboard: 200, phone: 112))
                CockpitThumbButton(title: L10n.Cockpit.check, subtitle: current?.challenge, icon: "checkmark",
                                   style: .filled(fill: theme.action, text: theme.actionText), action: onCheck)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(theme.panel)
            .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
        }
        .background(theme.background.ignoresSafeArea())
    }
}

// MARK: - The jump question (v6.0 review, J2-J3)

/// Before a jump that leaves two checks or more undone: defer them (listed, run later), or they were
/// already done (on paper, before the app), or stay. Nothing leaves the phase until one is picked.
struct JumpQuestionSheet: View {
    let target: ChecklistPhase
    /// The checks the jump leaves undone, in flight order.
    let checks: [ChecklistPhase]
    /// The phase being left, and how many of its items stay open (deferred one by one).
    let leaving: ChecklistPhase
    let leavingOpenItems: Int
    let onDefer: () -> Void
    let onAlreadyDone: () -> Void
    let onStay: () -> Void

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Jump.title(target.shortTitle))
                .font(.aero(size: 30, weight: .bold))
                .foregroundColor(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.Jump.checksLeft(checks.count, checks.map(\.shortTitle).joined(separator: ", ")))
                .font(.aero(size: 20))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if leavingOpenItems > 0 {
                Text(L10n.Jump.itemsKept(leavingOpenItems, leaving.shortTitle))
                    .font(.aero(size: 20))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                Button(action: onDefer) {
                    VStack(spacing: 4) {
                        Text(L10n.Jump.deferChecks(checks.count).uppercased())
                            .font(.aero(size: 22, weight: .heavy))
                        Text(L10n.Jump.deferHint).font(.aero(size: 17))
                    }
                    .foregroundColor(theme.actionText)
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(RoundedRectangle(cornerRadius: 16).fill(theme.action))
                }
                Button(action: onAlreadyDone) {
                    VStack(spacing: 4) {
                        Text(L10n.Jump.alreadyDone.uppercased())
                            .font(.aero(size: 22, weight: .heavy))
                        Text(L10n.Jump.alreadyDoneHint).font(.aero(size: 17))
                    }
                    .foregroundColor(theme.action)
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(RoundedRectangle(cornerRadius: 16).stroke(theme.action, lineWidth: 2))
                }
                Button(action: onStay) {
                    Text(L10n.Jump.stay(leaving.shortTitle))
                        .font(.aero(size: 20))
                        .foregroundColor(theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        // The panel fills the sheet; the question sits in its middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel.ignoresSafeArea())
    }
}

