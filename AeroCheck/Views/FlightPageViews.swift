import SwiftUI

// MARK: - The flight's page, its pieces (6.6.0)
//
// What both layouts draw with: the status line under the title, a chapter's head, a block's card (the iPad, A) and
// its row (the iPhone, C), the folded line a done or waiting block becomes, and the close-out card's buttons. Small
// view structs, so no body grows past what a device's main-thread stack takes.

/// The status line under the title (the author's round 2): when, then what's left, each item a tap that brings its
/// block. It replaces the ring, the chapter pills, the state chip and the NEXT card.
struct FlightStatusLine: View {
    let title: String
    let detail: String
    /// The blocks named in `detail`, with the words that name them there, in order.
    let items: [(kind: FlightBlockKind, words: String)]
    var isReady = false
    let onItem: (FlightBlockKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(size: 16, weight: .semibold, relativeTo: .headline)
                .foregroundColor(isReady ? .aviationGreen : .primaryText)
            if !detail.isEmpty {
                Text(linked)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if let index = Int(url.host() ?? ""), items.indices.contains(index) { onItem(items[index].kind) }
                        return .handled
                    })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flightPage.status")
    }

    /// `detail` with each item's words in gold, a link to its block.
    private var linked: AttributedString {
        var text = AttributedString(detail)
        var searchFrom = text.startIndex
        for (index, item) in items.enumerated() {
            guard let range = text[searchFrom...].range(of: item.words) else { continue }
            text[range].foregroundColor = .aviationGold
            text[range].link = URL(string: "aerocheck-block://\(index)")
            searchFrom = range.upperBound
        }
        return text
    }
}

/// A chapter's head: its name in gold capitals, and how much of it is done.
struct FlightChapterHead: View {
    let name: String
    var count: String?
    var color: Color = .aviationGold

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name.uppercased())
                .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(color)
                .tracking(1.2)
            Spacer(minLength: 8)
            if let count {
                Text(count)
                    .scaledFont(size: 11, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.dimText)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A block's tick: a circle to tick, filled green when done, a dash when set aside, dashed for what ticks itself,
/// dotted for what waits for the day.
struct FlightBlockTick: View {
    let state: FlightBlockState
    var isAuto = false
    var waits = false
    var isUrgent = false

    private var color: Color {
        switch state {
        case .done: return .aviationGreen
        case .notApplicable: return .dimText.opacity(0.5)
        case .pending: return isUrgent ? .aviationRed : .dimText
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: isAuto ? [3, 2] : waits ? [1, 2.5] : []))
                .frame(width: 22, height: 22)
            if state == .done {
                Circle().fill(color).frame(width: 22, height: 22)
                Image(systemName: "checkmark")
                    .scaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                    .foregroundColor(.cockpitBackground)
            } else if state == .notApplicable {
                Image(systemName: "minus")
                    .scaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                    .foregroundColor(.dimText)
            }
        }
        .frame(width: 44, height: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// What a block's head says on the right: a deadline in amber, a count or a time in grey, a verdict in green.
struct FlightBlockMeta: Equatable {
    enum Tone { case plain, deadline, good, caution }
    var text: String
    var tone: Tone = .plain

    var color: Color {
        switch tone {
        case .plain: return .secondaryText
        case .deadline, .caution: return .aviationAmber
        case .good: return .aviationGreen
        }
    }
}

/// A block on the iPad (A): its head with the one tick, the title and the meta, then its body. Done, set aside or
/// waiting for the day, it shows as a `FlightFoldedLine` instead; the page decides.
struct FlightBlockCard<Content: View, Accessory: View>: View {
    let block: FlightBlock
    let title: String
    var meta: FlightBlockMeta?
    /// "for the whole trip", the re-check line, and anything else under the title.
    var notes: [(String, Color)] = []
    let onTick: (() -> Void)?
    var onFold: (() -> Void)?
    var tickTarget: DryRunCoachStep.Target?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { onTick?() } label: {
                    FlightBlockTick(state: block.state, isAuto: block.isAuto, isUrgent: block.isUrgent)
                }
                .buttonStyle(.plain)
                .disabled(onTick == nil || block.isAuto)
                .accessibilityLabel(title)
                .accessibilityValue(block.state == .done ? L10n.Thread.markDone : "")
                .coachTarget(ifAny: tickTarget)
                Text(title)
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .headline)
                    .foregroundColor(block.state == .notApplicable ? .dimText : .primaryText)
                    .strikethrough(block.state == .notApplicable)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let meta {
                    Text(meta.text)
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(meta.color)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                accessory()
                if let onFold {
                    Button(action: onFold) {
                        Image(systemName: "chevron.up")
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundColor(.dimText)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Button.close)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note.0)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(note.1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 68)
                    .padding(.trailing, 14)
                    .padding(.bottom, 6)
            }
            content()
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// A block or a chapter as one line: done ("✓ Weather · Briefed at 12:05"), set aside, waiting for the day (a dotted
/// edge, "On the day of the flight"), or CLOSE before the landing. A tap opens it where it stands.
struct FlightFoldedLine: View {
    enum Look { case done, notApplicable, waiting }
    let look: Look
    let title: String
    var detail: String = ""
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FlightBlockTick(state: look == .done ? .done : look == .notApplicable ? .notApplicable : .pending,
                                waits: look == .waiting)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(look == .done ? .primaryText : .secondaryText)
                    if !detail.isEmpty {
                        Text(detail)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if chevron {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                        .foregroundColor(.dimText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .frame(minHeight: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(look == .waiting ? Color.clear : Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(look == .waiting ? 0.16 : 0.06),
                                  style: StrokeStyle(lineWidth: 1, dash: look == .waiting ? [4, 3] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A block on the iPhone (C): one checklist row. Its tick ticks the block; the rest of the row opens its sheet
/// (f5 A). The verdict on the right is the iPad head's meta.
struct FlightBlockRow: View {
    let block: FlightBlock
    let title: String
    var subtitle: String?
    var meta: FlightBlockMeta?
    let onTick: (() -> Void)?
    let onOpen: () -> Void
    var tickTarget: DryRunCoachStep.Target?

    var body: some View {
        HStack(spacing: 8) {
            Button { onTick?() } label: {
                FlightBlockTick(state: block.state, isAuto: block.isAuto, waits: block.waitsForDay && block.state == .pending,
                                isUrgent: block.isUrgent)
            }
            .buttonStyle(.plain)
            .disabled(onTick == nil || block.isAuto)
            .accessibilityLabel(title)
            .accessibilityValue(block.state == .done ? L10n.Thread.markDone : "")
            .coachTarget(ifAny: tickTarget)
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                            .foregroundColor(block.waitsForDay || block.state == .notApplicable ? .secondaryText : .primaryText)
                            .strikethrough(block.state == .notApplicable)
                            .multilineTextAlignment(.leading)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .scaledFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 6)
                    if let meta {
                        Text(meta.text)
                            .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                            .foregroundColor(meta.color)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.dimText)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

/// The close-out card's buttons (f8 A, the author's "ALS GESCHLOSSEN MAR…" of 24 Oct): one row when every label fits
/// whole at its size; else the calls in a row and MARK CLOSED under them, full width; else every button on its own
/// row. The words never change, whatever the language or the unit's name.
///
/// `call(i, whole)` and `mark(whole)` build the buttons; with `whole` their label keeps its natural width
/// (`CloseOutLabel`), which is what lets a rung be measured; the last rung lets a long name wrap instead.
struct CloseOutButtons<Call: View, Mark: View>: View {
    let calls: Int
    @ViewBuilder let call: (Int, Bool) -> Call
    @ViewBuilder let mark: (Bool) -> Mark

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(0..<calls, id: \.self) { call($0, true) }
                mark(true)
            }
            VStack(spacing: 8) {
                if calls > 0 {
                    HStack(spacing: 8) {
                        ForEach(0..<calls, id: \.self) { call($0, true) }
                    }
                }
                mark(true)
            }
            VStack(spacing: 8) {
                ForEach(0..<calls, id: \.self) { call($0, false) }
                mark(false)
            }
        }
    }
}

/// A close-out button's label: whole, at its natural width, for a rung that must fit; else up to two lines.
struct CloseOutLabel: View {
    let text: String
    let whole: Bool

    var body: some View {
        Text(text)
            .lineLimit(whole ? 1 : 2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: whole, vertical: false)
            .minimumScaleFactor(whole ? 1 : 0.7)
    }
}

/// A block of the iPhone's checklist, opened (C, the author's q2): the block as the iPad draws it, under a Done that
/// closes the sheet. At the large size, so a block reads without a second scroll in most cases.
struct FlightBlockSheet<Content: View>: View {
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(L10n.Button.done, action: onDone)
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
                    .foregroundColor(.aviationGold)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            ScrollView {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
            }
        }
        .background(Color.cockpitBackground.ignoresSafeArea())
    }
}

/// "Landed at EDSB, planned EDTF": the rest of the route as the next leg, or finish here (v5.1, the flight's page; on
/// Today too since 6.6.0, the author's t2 A). Finishing a trip's leg names its later legs and asks whether they go
/// (t5 A). An offer, never automatic: the pilot may stay the night, or take the train home.
struct LandedElsewhereOffer: View {
    let landed: LandedElsewhere
    /// The trip's later legs not flown, "Leg 3 · EDTF → LSZQ"; none for a flight on its own.
    let laterLegs: [String]
    let onContinue: () -> Void
    let onFinish: (_ cancellingLaterLegs: Bool) -> Void
    /// Landed at a later leg's destination (6.6.0, t3 A): its number and the stop flown past. The question comes
    /// first, skipped stop or diversion; "It was a diversion" shows the offer above.
    var skip: (number: Int, stop: String)?
    var onSkip: (() -> Void)?

    @State private var asking = false
    @State private var wasADiversion = false

    var body: some View {
        if let skip, let onSkip, !wasADiversion {
            skipQuestion(skip, onSkip: onSkip)
        } else {
            offer
        }
    }

    private func skipQuestion(_ skip: (number: Int, stop: String), onSkip: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.circle.fill")
                    .scaledFont(size: 18, relativeTo: .title3)
                    .foregroundColor(.aviationGold)
                Text(L10n.Trip.landedAtLegDestination(landed.landedIdent, skip.number))
                    .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(L10n.Trip.skipStopExplainer(landed.landedIdent))
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { skipButtons(skip, onSkip: onSkip) }
                VStack(spacing: 8) { skipButtons(skip, onSkip: onSkip) }
            }
        }
        .padding(14)
        .background(Color.aviationGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.aviationGold.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private func skipButtons(_ skip: (number: Int, stop: String), onSkip: @escaping () -> Void) -> some View {
        Button(action: onSkip) {
            Text(L10n.Trip.skipStop(skip.stop)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle(isLarge: false))
        Button { wasADiversion = true } label: {
            Text(L10n.Trip.itWasADiversion).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle(isLarge: false))
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .scaledFont(size: 18, relativeTo: .title3)
                    .foregroundColor(.aviationGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Trip.landedAt(landed.landedIdent))
                        .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                    Text("\(landed.landedName) · \(L10n.Trip.planned(landed.plannedIdent))")
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                }
                Spacer()
            }
            Text(L10n.Trip.continueExplainer(landed.landedIdent, landed.plannedIdent))
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onContinue) {
                    Text(L10n.Trip.continueTo(landed.plannedIdent))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(isLarge: false))
                Button {
                    if laterLegs.isEmpty { onFinish(false) } else { asking = true }
                } label: {
                    Text(L10n.Trip.finishHere)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(isLarge: false))
            }
        }
        .padding(14)
        .background(Color.aviationGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.aviationGold.opacity(0.5), lineWidth: 1))
        .confirmationDialog(L10n.Trip.laterLegsTitle, isPresented: $asking, titleVisibility: .visible) {
            Button(L10n.Trip.cancelLaterLegs, role: .destructive) { onFinish(true) }
            Button(L10n.Trip.keepLaterLegs) { onFinish(false) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            Text(laterLegs.joined(separator: "\n"))
        }
    }
}

/// A skipped leg's ATC flight plan, still filed (6.6.0, t6 A: remind, never act): cancel it where it was filed, then
/// Done. Not a task: nothing is stored but the reminder, and it goes with Done.
struct SkippedPlanReminder: View {
    let plans: String
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 16, relativeTo: .body)
                .foregroundColor(.aviationAmber)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.Trip.cancelSkippedPlanTitle(plans))
                    .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.Trip.cancelSkippedPlanBody)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(L10n.Button.done, action: onDone)
                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                .foregroundColor(.aviationGold)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(14)
        .background(Color.aviationAmber.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.aviationAmber.opacity(0.5), lineWidth: 1))
    }
}
