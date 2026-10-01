import Foundation

// MARK: - Deletion records (6.1)
//
// "Sync to iCloud" keeps two stores, iCloud Drive and the local one, and copies the store being left
// into the one taken up. A file deleted in one store was still in the other, so a deletion made while
// the switch was off came back when it went on, and a flight deleted while on came back from the
// stale local copy at the next switch-off. Nothing could tell a copy merely missing from a store from
// a copy the pilot deleted.
//
// A deletion record says it: one small file per item deleted on purpose, in the store's
// `.Deletions` folder. One rule everywhere: a copy is dead when its content stamp (`modifiedAt` for
// a flight, `updatedAt` for the rest) is not later than its record's `deletedAt`. A copy edited
// after the deletion, on a device that did not know yet, is alive: a later edit beats an older
// delete. (review design 94)
//
// Records are written only where the pilot deletes something (`DataPersistenceManager.recordDeletion`),
// never by the file deletes that tidy up after a rename or by the CloudKit ingest: those remove files
// of items that live on. Absence is never read as deletion. Every failure to read a record means "no
// record": an item may come back, it never disappears.

/// One item deleted on purpose: `<store>/.Deletions/<kind>_<UUID>.json`.
///
/// One file per item rather than one ledger: two devices writing one ledger through iCloud Drive make
/// a conflict and one side is lost, whereas separate files merge by plain union. No device field: no
/// rule needs it, and a device name is personal data.
///
/// The synthesised decoder requires every field, so a field added later must be optional (the
/// Codable trap: a required one makes every older record unreadable, which reads as "no record").
struct DeletionRecord: Codable, Equatable, Sendable {

    enum Kind: String, CaseIterable, Sendable {
        case flight, plan, thread, trip
    }

    /// The format: 1.
    var v: Int = 1
    /// A `Kind` raw value. A string, so a kind a later build adds reads as unknown and is skipped
    /// rather than failing the decode.
    var kind: String
    var id: UUID
    var deletedAt: Date

    init(kind: Kind, id: UUID, deletedAt: Date) {
        self.kind = kind.rawValue
        self.id = id
        self.deletedAt = deletedAt
    }

    var knownKind: Kind? { Kind(rawValue: kind) }
}

/// The records of one or two stores, read: the latest deletion per item.
struct DeletionLedger: Equatable, Sendable {

    struct Key: Hashable, Sendable {
        let kind: DeletionRecord.Kind
        let id: UUID
    }

    /// What is known of an item's deletion. `deletedAt` is the latest date read; `undated` is set
    /// when a record could not be read yet (iCloud has evicted it), whose date may be later still.
    struct Mark: Equatable, Sendable {
        var deletedAt: Date?
        var undated = false
    }

    enum Verdict: Equatable, Sendable {
        /// No record covers the copy: it lives.
        case alive
        /// Not edited since its deletion.
        case dead
        /// Only a record not downloaded yet could cover it. Not copied anywhere, never retired: the
        /// decision waits for the record.
        case unknown
    }

    private(set) var marks: [Key: Mark] = [:]

    static let empty = DeletionLedger()

    var isEmpty: Bool { marks.isEmpty }

    func contains(_ kind: DeletionRecord.Kind) -> Bool {
        marks.keys.contains { $0.kind == kind }
    }

    func mark(_ kind: DeletionRecord.Kind, id: UUID) -> Mark? {
        marks[Key(kind: kind, id: id)]
    }

    /// The first 8 characters of every recorded id of `kind`, as file names carry them.
    func idPrefixes(of kind: DeletionRecord.Kind) -> Set<String> {
        Set(marks.keys.filter { $0.kind == kind }.map { String($0.id.uuidString.prefix(8)) })
    }

    /// A record's date, or nil for one not downloaded yet. The later date wins.
    mutating func note(_ kind: DeletionRecord.Kind, id: UUID, deletedAt: Date?) {
        var mark = marks[Key(kind: kind, id: id)] ?? Mark()
        if let deletedAt {
            mark.deletedAt = max(mark.deletedAt ?? deletedAt, deletedAt)
        } else {
            mark.undated = true
        }
        marks[Key(kind: kind, id: id)] = mark
    }

    /// The union of two ledgers, the latest deletion per item.
    func merging(_ other: DeletionLedger) -> DeletionLedger {
        var result = self
        for (key, mark) in other.marks {
            if let deletedAt = mark.deletedAt { result.note(key.kind, id: key.id, deletedAt: deletedAt) }
            if mark.undated { result.note(key.kind, id: key.id, deletedAt: nil) }
        }
        return result
    }

    /// Whether the copy of `id` whose content stamp is `stamp` was deleted.
    func verdict(_ kind: DeletionRecord.Kind, id: UUID, stamp: Date) -> Verdict {
        guard let mark = marks[Key(kind: kind, id: id)] else { return .alive }
        if let deletedAt = mark.deletedAt, DeletionRecords.isDead(stamp: stamp, deletedAt: deletedAt) { return .dead }
        return mark.undated ? .unknown : .alive
    }

    func isDead(_ kind: DeletionRecord.Kind, id: UUID, stamp: Date) -> Bool {
        verdict(kind, id: id, stamp: stamp) == .dead
    }
}

/// What a loader needs to leave the dead items out: the active store's records, and where their
/// files go (`DeletionRecords.retire`).
struct DeletionFilter: Sendable {
    let ledger: DeletionLedger
    let retiredRoot: URL
    let now: Date

    /// The records of `storeRoot` for `kinds`; nil when there are none, the loaders' fast path.
    static func reading(storeRoot: URL, retiredRoot: URL, kinds: Set<DeletionRecord.Kind>,
                        now: Date = Date()) -> DeletionFilter? {
        let ledger = DeletionRecords.read(storeRoot: storeRoot, kinds: kinds, now: now)
        return ledger.isEmpty ? nil : DeletionFilter(ledger: ledger, retiredRoot: retiredRoot, now: now)
    }

    func isDead(_ kind: DeletionRecord.Kind, id: UUID, stamp: Date) -> Bool {
        ledger.isDead(kind, id: id, stamp: stamp)
    }

    @discardableResult
    func retire(_ file: URL, kind: DeletionRecord.Kind) -> Bool {
        DeletionRecords.retire(file, kind: kind, retiredRoot: retiredRoot, now: now, fileManager: .default)
    }
}

/// The records' files: where they live, how they are read, written, applied and pruned.
enum DeletionRecords {

    /// The folder in each store's root. Hidden on purpose: iCloud Drive's Documents is what the pilot
    /// browses in Files, and a visible "Deletions" folder invites a clean-up (records lost = items
    /// back). If iCloud Drive turns out not to sync a dot-folder (device check), this one constant
    /// becomes a visible name.
    static let folderName = ".Deletions"

    /// Where the dead copies go, in the LOCAL store's root (Application Support, never synced):
    /// `Retired/<kind>/`. A merge or a load removes a dead copy only after copying it there.
    static let retiredFolderName = "Retired"

    /// How long a record lives (author, 2026-10-01). A store not merged for longer can bring an item
    /// back, never lose one.
    static let recordLifetime: TimeInterval = 400 * 86_400
    /// How long a retired copy is kept.
    static let retiredLifetime: TimeInterval = 30 * 86_400
    /// A record is ~120 bytes; anything much larger is not one.
    static let maxRecordBytes = 4 * 1024

    static func folder(in storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    static func fileName(_ kind: DeletionRecord.Kind, id: UUID) -> String {
        "\(kind.rawValue)_\(id.uuidString).json"
    }

    /// `<kind>_<UUID>.json` → its kind and id. Nil for any other name.
    static func parseFileName(_ name: String) -> (kind: DeletionRecord.Kind, id: UUID)? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(".json".count)
        guard let underscore = stem.firstIndex(of: "_"),
              let kind = DeletionRecord.Kind(rawValue: String(stem[..<underscore])),
              let id = UUID(uuidString: String(stem[stem.index(after: underscore)...])) else { return nil }
        return (kind, id)
    }

    // MARK: Stamps

    /// The rule: a copy is dead when its stamp is not later than the deletion. Compared in whole
    /// seconds, as the files store their dates (ISO 8601 without fractions): the copy on disk of an
    /// item deleted in the same second as its last edit must read as dead, like the one in memory.
    static func isDead(stamp: Date, deletedAt: Date) -> Bool {
        stamp.timeIntervalSince1970.rounded(.down) <= deletedAt.timeIntervalSince1970.rounded(.down)
    }

    /// A content stamp no record dated `deletedAt` covers, for an item that must outlive it (an
    /// import, a plan being flown). Nil (a record not downloaded yet) gives now.
    static func stamp(after deletedAt: Date?, now: Date = Date()) -> Date {
        guard let deletedAt else { return now }
        return max(now, Date(timeIntervalSince1970: deletedAt.timeIntervalSince1970.rounded(.down) + 1))
    }

    // MARK: Reading and writing

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ record: DeletionRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    /// The record in `url`, or nil for anything that is not a usable one: too large, undecodable, of
    /// an unknown kind, or dated beyond the clock skew any ingest accepts (a poisoned date would
    /// otherwise kill every later edit).
    static func readRecord(at url: URL, now: Date = Date()) -> DeletionRecord? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxRecordBytes,
              let data = try? Data(contentsOf: url),
              let record = try? makeDecoder().decode(DeletionRecord.self, from: data),
              record.knownKind != nil,
              record.deletedAt <= now.addingTimeInterval(FlightDataLimits.maxClockSkew) else { return nil }
        return record
    }

    /// Every record in `storeRoot` of the given kinds. A record iCloud has evicted
    /// (`.<kind>_<UUID>.json.icloud`) gives its kind and id by its name and no date: "deleted, date
    /// unknown". Its download is requested, so a later pass reads it.
    static func read(storeRoot: URL, kinds: Set<DeletionRecord.Kind> = Set(DeletionRecord.Kind.allCases),
                     now: Date = Date(), fileManager: FileManager = .default) -> DeletionLedger {
        let folder = folder(in: storeRoot)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return .empty }
        var ledger = DeletionLedger()
        for name in names {
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                guard let (kind, id) = parseFileName(real), kinds.contains(kind) else { continue }
                try? fileManager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                ledger.note(kind, id: id, deletedAt: nil)
                continue
            }
            guard let (kind, id) = parseFileName(name), kinds.contains(kind) else { continue }
            let url = folder.appendingPathComponent(name)
            guard DataPersistenceManager.isLocallyMaterialized(url) else {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                ledger.note(kind, id: id, deletedAt: nil)
                continue
            }
            // The name and the content must agree: a record is never applied to another item.
            guard let record = readRecord(at: url, now: now), record.knownKind == kind, record.id == id else { continue }
            ledger.note(kind, id: id, deletedAt: record.deletedAt)
        }
        return ledger
    }

    /// The record of one item in `storeRoot`, if any: one file read, for the import.
    static func mark(_ kind: DeletionRecord.Kind, id: UUID, storeRoot: URL, now: Date = Date(),
                     fileManager: FileManager = .default) -> DeletionLedger.Mark? {
        let url = folder(in: storeRoot).appendingPathComponent(fileName(kind, id: id))
        if fileManager.fileExists(atPath: url.path) {
            guard DataPersistenceManager.isLocallyMaterialized(url) else { return DeletionLedger.Mark(undated: true) }
            guard let record = readRecord(at: url, now: now), record.knownKind == kind, record.id == id else { return nil }
            return DeletionLedger.Mark(deletedAt: record.deletedAt)
        }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fileManager.fileExists(atPath: placeholder.path) ? DeletionLedger.Mark(undated: true) : nil
    }

    /// Writes the record of `id` into `storeRoot`, replacing an older record for it, never a later
    /// one (written by a device whose clock runs ahead).
    @discardableResult
    static func write(_ kind: DeletionRecord.Kind, id: UUID, deletedAt: Date, storeRoot: URL,
                      fileManager: FileManager = .default) -> Bool {
        let folder = folder(in: storeRoot)
        let url = folder.appendingPathComponent(fileName(kind, id: id))
        if let present = readRecord(at: url, now: deletedAt), present.id == id, present.deletedAt >= deletedAt {
            return true
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try encode(DeletionRecord(kind: kind, id: id, deletedAt: deletedAt))
                .write(to: url, options: DataPersistenceManager.protectedWriteOptions)
            return true
        } catch {
            AppLog.general.debugLine("Could not record the deletion of a \(kind.rawValue): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Probing a file

    /// The identity and content stamps of a model file, without the rest of it.
    private struct Probe: Decodable {
        let id: UUID
        let modifiedAt: Date?
        let updatedAt: Date?
        let stopTime: Date?
        let startTime: Date?
    }

    /// The id and content stamp of the `kind` file at `url`; nil when it does not read as one, which
    /// leaves the file alive. A flight without `modifiedAt` (written before v5) stamps as its decoder
    /// does: its stop, else its start.
    static func probe(_ url: URL, kind: DeletionRecord.Kind) -> (id: UUID, stamp: Date)? {
        guard let data = try? Data(contentsOf: url),
              let probe = try? makeDecoder().decode(Probe.self, from: data) else { return nil }
        switch kind {
        case .flight:
            return (probe.id, probe.modifiedAt ?? probe.stopTime ?? probe.startTime ?? .distantPast)
        case .plan, .thread, .trip:
            return probe.updatedAt.map { (probe.id, $0) }
        }
    }

    /// Whether the file named `name` could hold one of the recorded items. Flight, page and (since
    /// 6.1) plan files end with the first 8 characters of their id: only those matching a record
    /// are opened. A name without that suffix (a flight from before PR-19, a plan from before 6.1)
    /// could be anything and is opened too. The id is then read in full: never the suffix alone.
    static func needsProbe(_ name: String, prefixes: Set<String>) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(".json".count)
        guard let underscore = stem.lastIndex(of: "_") else { return true }
        let suffix = stem[stem.index(after: underscore)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isHexDigit) else { return true }
        return prefixes.contains(suffix.uppercased())
    }

    // MARK: Retiring

    /// Copies a dead file into `Retired/<kind>/` and removes the original. A copy and a removal, the
    /// way every delete here works, rather than a move out of the iCloud container. Nothing is removed
    /// unless the copy succeeded.
    @discardableResult
    static func retire(_ file: URL, kind: DeletionRecord.Kind, retiredRoot: URL, now: Date,
                       fileManager: FileManager) -> Bool {
        guard park(file, kind: kind, retiredRoot: retiredRoot, now: now, fileManager: fileManager) else { return false }
        do {
            try fileManager.removeItem(at: file)
            return true
        } catch {
            AppLog.general.debugLine("Could not remove a retired \(kind.rawValue) file: \(error.localizedDescription)")
            return false
        }
    }

    /// Copies `file` into `Retired/<kind>/`, stamped `now` for the purge, under a name of its own.
    @discardableResult
    static func park(_ file: URL, kind: DeletionRecord.Kind, retiredRoot: URL, now: Date,
                     fileManager: FileManager) -> Bool {
        let folder = retiredRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let stem = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            var target = folder.appendingPathComponent(file.lastPathComponent)
            var counter = 2
            while fileManager.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(ext)
                counter += 1
            }
            try fileManager.copyItem(at: file, to: target)
            try? fileManager.setAttributes(
                [.modificationDate: now, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: target.path)
            return true
        } catch {
            AppLog.general.debugLine("Could not retire a \(kind.rawValue) file: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Pruning

    /// Removes the records of `storeRoot` older than `recordLifetime` and the retired copies older
    /// than `retiredLifetime`. Run at launch, after the owed merge, off the main thread, on the
    /// active store only: the other store keeps its records until it is the active one. A record not
    /// downloaded, or unreadable, is left alone.
    @discardableResult
    static func prune(storeRoot: URL, retiredRoot: URL, now: Date = Date(),
                      fileManager: FileManager = .default) -> (records: Int, retired: Int) {
        var records = 0
        let folder = folder(in: storeRoot)
        let recordCutoff = now.addingTimeInterval(-recordLifetime)
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where parseFileName(name) != nil {
            let url = folder.appendingPathComponent(name)
            guard DataPersistenceManager.isLocallyMaterialized(url),
                  let record = readRecord(at: url, now: now), record.deletedAt < recordCutoff,
                  (try? fileManager.removeItem(at: url)) != nil else { continue }
            records += 1
        }
        var retired = 0
        let retiredCutoff = now.addingTimeInterval(-retiredLifetime)
        for kind in DeletionRecord.Kind.allCases {
            let kindFolder = retiredRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(
                at: kindFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files {
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, modified < retiredCutoff,
                      (try? fileManager.removeItem(at: url)) != nil else { continue }
                retired += 1
            }
        }
        return (records, retired)
    }
}
