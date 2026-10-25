import Combine
import Foundation
import UIKit

/// The pilot's aerodrome notes (6.7.0): one file each in the datastore's `AerodromeNotes` folder, so
/// they follow "Sync to iCloud" as routes and threads do (n5 A), and nowhere else.
///
/// `.shared` is the app's, on the app's datastore; the maps' coordinators read it, since a MapKit
/// delegate can't reach the environment. Tests build their own on a test datastore.
@MainActor
final class AerodromeNoteStore: ObservableObject {
    static let shared = AerodromeNoteStore()

    @Published private(set) var notes: [AerodromeNote] = []
    @Published private(set) var hasLoaded = false

    private let persistence: DataPersistenceManager
    private var datastoreMoves: AnyCancellable?
    /// What a save or delete made here, by the change's sequence number: a load that read the folder
    /// before the change reached it must not undo it. A delete is forgotten once a load started after it, a save
    /// once its file is written and a load started after it: forgotten as soon as written, a save was dropped by a
    /// load that had read the folder before the file came, and the next save on that aerodrome made a second note.
    private struct LocalChange {
        var note: AerodromeNote?
        let seq: Int
        var written = false
    }
    private var localChanges: [UUID: LocalChange] = [:]
    private var seq = 0
    /// The last load asked for; each waits for the one before. Two at once (the store's own first one and a caller's)
    /// both read the folder, and the one that ended last could keep a copy the other had just folded into its twin.
    private var loading: Task<Void, Never>?

    init(persistence: DataPersistenceManager? = nil) {
        self.persistence = persistence ?? DataPersistenceManager.shared
        Task { [weak self] in await self?.reload() }
        // "Sync to iCloud" moved the datastore: read what the store taken up holds.
        datastoreMoves = NotificationCenter.default
            .publisher(for: .datastoreLocationDidChange, object: self.persistence)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.reload() } }
    }

    /// Whether the notes sit in iCloud Drive right now, or on this device only.
    var isInICloud: Bool { persistence.isUsingICloudDrive }

    // MARK: Reading

    func note(for ref: AerodromeRef) -> AerodromeNote? {
        notes.first { AerodromeNoteMatch.matches($0, ref) }
    }

    func note(for airport: Airport) -> AerodromeNote? { note(for: AerodromeRef(airport)) }

    /// The notes whose aerodrome or text holds `query`, accents and case aside; every note for an
    /// empty query.
    func notes(matching query: String) -> [AerodromeNote] {
        let q = AerodromeNoteMatch.folded(query)
        guard !q.isEmpty else { return notes }
        return notes.filter { note in
            [note.ident, note.name, note.arrival, note.onTheGround].contains { AerodromeNoteMatch.folded($0).contains(q) }
        }
    }

    // MARK: Writing

    /// Saves the note's text for `ref`: a new note when it has none, the existing one changed
    /// otherwise. Nothing left in either part deletes the note. Returns the file's write.
    @discardableResult
    func save(arrival: String, onTheGround: String, for ref: AerodromeRef, now: Date = Date()) -> Task<Void, Never>? {
        var note = note(for: ref) ?? AerodromeNote(ident: ref.ident, name: ref.name, latitude: ref.latitude,
                                                   longitude: ref.longitude, createdAt: now, updatedAt: now)
        note.arrival = arrival
        note.onTheGround = onTheGround
        guard !note.isEmpty else {
            if let existing = self.note(for: ref) { delete(existing, now: now) }
            return nil
        }
        // The data's current identifier and name, so the file follows a renamed field.
        note.ident = ref.ident
        note.name = ref.name
        note.updatedAt = now
        note.editedOn = Self.deviceKind
        put(note)
        seq += 1
        let mine = seq
        localChanges[note.id] = LocalChange(note: note, seq: mine)
        return Task {
            let written = await persistence.saveAerodromeNotesOffMain([note])
            if written.contains(note.id), localChanges[note.id]?.seq == mine { localChanges[note.id]?.written = true }
        }
    }

    /// Deletes a note here and, through iCloud Drive, on the pilot's other devices. The deletion is
    /// recorded first, so a copy in the other store (the switch's) stays deleted too.
    func delete(_ note: AerodromeNote, now: Date = Date()) {
        notes.removeAll { $0.id == note.id }
        seq += 1
        localChanges[note.id] = LocalChange(note: nil, seq: seq)
        persistence.recordDeletion(.aerodromeNote, id: note.id, stamp: note.updatedAt, at: now)
        persistence.deleteAerodromeNoteFile(note)
    }

    func deleteAll(now: Date = Date()) {
        for note in notes { delete(note, now: now) }
    }

    // MARK: Loading

    /// Reads the folder again: at launch, back in the foreground, after a store move. What iCloud
    /// brought from another device joins, and two notes on one aerodrome become one.
    func reload() async {
        let previous = loading
        let load = Task { [weak self] in
            await previous?.value
            await self?.load()
        }
        loading = load
        await load.value
    }

    private func load() async {
        let startedAt = seq
        let loaded = await persistence.loadAerodromeNotesOffMain()
        var byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        for (id, change) in localChanges {
            if let note = change.note {
                if (byId[id]?.updatedAt ?? .distantPast) < note.updatedAt { byId[id] = note }
                if change.written && change.seq <= startedAt { localChanges[id] = nil }
            } else {
                byId[id] = nil
                if change.seq <= startedAt { localChanges[id] = nil }
            }
        }
        let collapsed = AerodromeNoteMerge.collapse(Array(byId.values))
        notes = collapsed.kept.sorted { $0.ident < $1.ident }
        hasLoaded = true
        for folded in collapsed.folded {
            persistence.recordDeletion(.aerodromeNote, id: folded.id, stamp: folded.updatedAt)
            persistence.deleteAerodromeNoteFile(folded)
        }
        if !collapsed.rewritten.isEmpty {
            await persistence.saveAerodromeNotesOffMain(collapsed.rewritten)
        }
    }

    private func put(_ note: AerodromeNote) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
            notes.sort { $0.ident < $1.ident }
        }
    }

    /// "iPad" or "iPhone": the kind of device, never its name (personal data).
    static var deviceKind: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}
