import SwiftUI

// MARK: - The pilot's note on an aerodrome (6.7.0)
//
// Two parts, both free text (n1 A): Arrival, which the Cockpit shows, and On the ground. Written on
// the ground; in flight the same sheet only reads (n3 A). Cancel and Done when it edits, one Close
// when it only reads (Apple's rule, #518).

/// A note's text with its links and phone numbers made taps, for reading.
enum AerodromeNoteText {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            if let url = match.url {
                result[lower..<upper].link = url
            } else if let phone = match.phoneNumber,
                      let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                result[lower..<upper].link = url
            }
        }
        return result
    }
}

struct AerodromeNoteSheet: View {
    let aerodrome: AerodromeRef
    /// In flight: the note is read, never edited.
    var readOnly = false

    @EnvironmentObject private var store: AerodromeNoteStore
    @Environment(\.dismiss) private var dismiss

    @State private var arrival = ""
    @State private var onTheGround = ""
    @State private var loaded = false
    @State private var confirmingDelete = false

    private var note: AerodromeNote? { store.note(for: aerodrome) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if readOnly {
                        readingBody
                    } else {
                        part(L10n.AerodromeNotes.arrival, hint: L10n.AerodromeNotes.arrivalHint, text: $arrival,
                             id: "aerodromeNote.arrival")
                        part(L10n.AerodromeNotes.onTheGround, hint: L10n.AerodromeNotes.onTheGroundHint,
                             text: $onTheGround, id: "aerodromeNote.onTheGround")
                    }
                    if let note { metaLine(note) }
                    if !readOnly, note != nil {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Text(L10n.AerodromeNotes.delete)
                                .scaledFont(size: 16, relativeTo: .body)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier("aerodromeNote.delete")
                    }
                }
                .padding(16)
            }
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle(aerodrome.ident)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(aerodrome.ident)
                            .scaledFont(size: 16, weight: .bold, design: .monospaced, relativeTo: .headline)
                        Text(aerodrome.name)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                if readOnly {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.Button.close) { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.Button.cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.Button.done) {
                            save()
                            dismiss()
                        }
                        .fontWeight(.bold)
                        .accessibilityIdentifier("aerodromeNote.done")
                    }
                }
            }
            .confirmationDialog(L10n.AerodromeNotes.deleteQuestion(aerodrome.ident), isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button(L10n.AerodromeNotes.delete, role: .destructive) {
                    if let note { store.delete(note) }
                    dismiss()
                }
                Button(L10n.Button.cancel, role: .cancel) {}
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            arrival = note?.arrival ?? ""
            onTheGround = note?.onTheGround ?? ""
        }
    }

    // MARK: Editing

    private func part(_ title: String, hint: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title, hint: hint)
            TextEditor(text: text)
                .scaledFont(size: 17, relativeTo: .body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(hint)
                            .scaledFont(size: 17, relativeTo: .body)
                            .foregroundColor(.secondaryText.opacity(0.7))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
        }
    }

    private func save() {
        guard !readOnly else { return }
        let before = (note?.arrival ?? "", note?.onTheGround ?? "")
        guard (arrival, onTheGround) != before else { return }
        store.save(arrival: arrival, onTheGround: onTheGround, for: aerodrome)
    }

    // MARK: Reading

    @ViewBuilder private var readingBody: some View {
        if let note {
            if note.hasArrival { reading(L10n.AerodromeNotes.arrival, note.arrival) }
            if !AerodromeNote.trimmed(note.onTheGround).isEmpty { reading(L10n.AerodromeNotes.onTheGround, note.onTheGround) }
            Text(L10n.AerodromeNotes.readOnlyInFlight)
                .scaledFont(size: 13, relativeTo: .caption)
                .foregroundColor(.secondaryText)
        }
    }

    private func reading(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title, hint: nil)
            Text(AerodromeNoteText.attributed(AerodromeNote.trimmed(text)))
                .scaledFont(size: 20, relativeTo: .body)
                .foregroundColor(.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
                .textSelection(.enabled)
        }
    }

    // MARK: Shared

    private func sectionTitle(_ title: String, hint: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption)
                .tracking(1.4)
                .foregroundColor(.aviationGold)
            Spacer(minLength: 8)
            if let hint {
                Text(hint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
            }
        }
    }

    private func metaLine(_ note: AerodromeNote) -> some View {
        let date = note.updatedAt.formatted(date: .abbreviated, time: .omitted)
        let changed = note.editedOn.map { L10n.AerodromeNotes.changed(date, on: $0) } ?? date
        let place = store.isInICloud ? L10n.AerodromeNotes.inICloud : L10n.AerodromeNotes.onThisDevice
        return Text("\(changed) · \(place)")
            .scaledFont(size: 13, relativeTo: .caption)
            .foregroundColor(.secondaryText)
    }
}
