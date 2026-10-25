import SwiftUI

/// Settings › Sync & Data › Aerodrome notes (6.7.0, n6 A): every note by aerodrome, a search that also
/// reads inside the notes, one text file of them all to share, and deletion of one (swipe) or all.
struct AerodromeNotesSettingsView: View {
    @ObservedObject private var store = AerodromeNoteStore.shared

    @State private var query = ""
    @State private var editing: AerodromeNote?
    @State private var sharing: Data?
    @State private var confirmingDeleteAll = false

    private let tint: Color = .altimeterBlue

    private var shown: [AerodromeNote] { store.notes(matching: query) }

    var body: some View {
        List {
            if store.notes.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.AerodromeNotes.empty)
                            .scaledFont(size: 17, weight: .semibold, relativeTo: .headline)
                            .foregroundColor(.primaryText)
                        Text(L10n.AerodromeNotes.emptyHint)
                            .scaledFont(size: 15, relativeTo: .subheadline)
                            .foregroundColor(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    if shown.isEmpty {
                        Text(L10n.AerodromeNotes.noMatch)
                            .scaledFont(size: 15, relativeTo: .subheadline)
                            .foregroundColor(.secondaryText)
                    }
                    ForEach(shown) { note in
                        Button { editing = note } label: { row(note) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("aerodromeNotes.row.\(note.ident)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { store.delete(note) } label: {
                                    Label(L10n.Button.delete, systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text(L10n.AerodromeNotes.footer)
                }
                Section {
                    Button { sharing = exportData() } label: {
                        Label(L10n.AerodromeNotes.shareAll, systemImage: "square.and.arrow.up")
                            .foregroundColor(tint)
                    }
                    .accessibilityIdentifier("aerodromeNotes.shareAll")
                    Button(role: .destructive) { confirmingDeleteAll = true } label: {
                        Label(L10n.AerodromeNotes.deleteAll, systemImage: "trash")
                    }
                    .accessibilityIdentifier("aerodromeNotes.deleteAll")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.cockpitBackground.ignoresSafeArea())
        .searchable(text: $query, prompt: L10n.AerodromeNotes.search)
        .navigationTitle(L10n.AerodromeNotes.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reload() }
        .sheet(item: $editing) { note in
            AerodromeNoteSheet(aerodrome: AerodromeRef(ident: note.ident, name: note.name,
                                                       latitude: note.latitude, longitude: note.longitude))
                .environmentObject(store)
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let data = sharing {
                ShareSheet(activityItems: [
                    ShareFile(data: data, filename: L10n.AerodromeNotes.exportFileName + ".txt",
                              dataTypeIdentifier: "public.plain-text")
                ])
            }
        }
        .confirmationDialog(L10n.AerodromeNotes.deleteAllQuestion, isPresented: $confirmingDeleteAll,
                            titleVisibility: .visible) {
            Button(L10n.AerodromeNotes.deleteAllConfirm, role: .destructive) { store.deleteAll() }
            Button(L10n.Button.cancel, role: .cancel) {}
        }
    }

    private func row(_ note: AerodromeNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(note.ident)
                .scaledFont(size: 15, weight: .bold, design: .monospaced, relativeTo: .body)
                .foregroundColor(.primaryText)
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.name)
                    .scaledFont(size: 15, relativeTo: .body)
                    .foregroundColor(.primaryText)
                Text(note.firstLine)
                    .scaledFont(size: 13, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
                Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .scaledFont(size: 12, relativeTo: .caption2)
                    .foregroundColor(.dimText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                .foregroundColor(.dimText)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func exportData() -> Data {
        let date = Date().formatted(date: .abbreviated, time: .omitted)
        let text = AerodromeNoteExport.text(store.notes, arrivalTitle: L10n.AerodromeNotes.arrival,
                                            groundTitle: L10n.AerodromeNotes.onTheGround,
                                            header: L10n.AerodromeNotes.exportHeader(date))
        return Data(text.utf8)
    }
}
