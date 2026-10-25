import XCTest
@testable import AeroCheck

/// The pilot's aerodrome notes (6.7.0): which aerodrome a note is on, two copies made one, the text
/// export, and the store's files in the datastore (written, renamed, deleted, merged by the switch).
@MainActor
final class AerodromeNotesTests: XCTestCase {

    private let grenchen = AerodromeRef(ident: "LSZG", name: "Grenchen", latitude: 47.1816, longitude: 7.4172)

    private func note(_ ident: String = "LSZG", name: String = "Grenchen", lat: Double = 47.1816, lon: Double = 7.4172,
                      arrival: String = "", ground: String = "", updated: TimeInterval = 0) -> AerodromeNote {
        AerodromeNote(ident: ident, name: name, latitude: lat, longitude: lon, arrival: arrival, onTheGround: ground,
                      createdAt: Date(timeIntervalSince1970: updated), updatedAt: Date(timeIntervalSince1970: updated))
    }

    // MARK: Matching

    func testANoteMatchesItsAerodromeByIdentifierWhateverTheCase() {
        XCTAssertTrue(AerodromeNoteMatch.matches(note("lszg"), grenchen))
        XCTAssertFalse(AerodromeNoteMatch.matches(note("LSZB", name: "Bern"), grenchen))
    }

    func testANoteWrittenUnderAnotherCodeOfTheFieldStillMatches() {
        // OurAirports names a field without an ICAO code "CH-0002"; the data later gives it LSYQ.
        let ref = AerodromeRef(ident: "LSYQ", name: "Hasenstrick", latitude: 47.29, longitude: 8.86, otherIdents: ["CH-0002"])
        XCTAssertTrue(AerodromeNoteMatch.matches(note("CH-0002", name: "Hasenstrick", lat: 47.29, lon: 8.86), ref))
    }

    func testTheSameNameMatchesWithinAKilometreOnly() {
        let renamed = note("XX-0001", name: "GRENCHEN")
        XCTAssertTrue(AerodromeNoteMatch.matches(renamed, grenchen))
        // 0.02° of latitude is about 2.2 km: another field of the same name, not this one.
        XCTAssertFalse(AerodromeNoteMatch.matches(note("XX-0001", name: "Grenchen", lat: 47.2016), grenchen))
        // Accents never stop a match.
        let ecu = AerodromeRef(ident: "LSGE", name: "Écuvillens", latitude: 46.755, longitude: 7.076)
        XCTAssertTrue(AerodromeNoteMatch.matches(note("XX", name: "ecuvillens", lat: 46.755, lon: 7.076), ecu))
    }

    // MARK: Two copies made one

    func testTwoNotesOnOneAerodromeBecomeTheNewerWithTheOlderTextUnderIt() {
        let older = note(arrival: "Gliders at weekends.", ground: "Fuel at the pump.", updated: 100)
        let newer = note(arrival: "Ask for the circuit early.", updated: 200)
        let result = AerodromeNoteMerge.collapse([older, newer])
        XCTAssertEqual(result.kept.count, 1)
        XCTAssertEqual(result.kept[0].id, newer.id)
        XCTAssertEqual(result.kept[0].arrival, "Ask for the circuit early.\n\nGliders at weekends.")
        XCTAssertEqual(result.kept[0].onTheGround, "Fuel at the pump.")
        XCTAssertEqual(result.rewritten.map(\.id), [newer.id])
        XCTAssertEqual(result.folded.map(\.id), [older.id])
    }

    func testTextTheNewerAlreadyHoldsIsNotAddedTwice() {
        let older = note(arrival: "Gliders at weekends.", updated: 100)
        let newer = note(arrival: "Gliders at weekends. And the circuit is tight.", updated: 200)
        XCTAssertEqual(AerodromeNoteMerge.collapse([older, newer]).kept[0].arrival, newer.arrival)
    }

    func testNotesOnDifferentAerodromesAreNeverFoldedTogether() {
        let result = AerodromeNoteMerge.collapse([note("LSZG", arrival: "a"), note("LSPL", name: "Langenthal", arrival: "b")])
        XCTAssertEqual(result.kept.count, 2)
        XCTAssertTrue(result.folded.isEmpty)
        XCTAssertTrue(result.rewritten.isEmpty)
    }

    // MARK: The text export

    func testTheExportListsEachNoteByAerodromeWithItsParts() {
        let text = AerodromeNoteExport.text(
            [note("LSZS", name: "Samedan", arrival: "Valley wind after noon."),
             note("LSZG", arrival: "Ask early.", ground: "Fuel at the pump."),
             note("LSPL", name: "Langenthal")],
            arrivalTitle: "Arrival", groundTitle: "On the ground", header: "AéroCheck · Aerodrome notes · 25 Oct 2026")
        XCTAssertEqual(text, """
            AéroCheck · Aerodrome notes · 25 Oct 2026

            LSZG Grenchen
            ARRIVAL
            Ask early.
            ON THE GROUND
            Fuel at the pump.

            LSZS Samedan
            ARRIVAL
            Valley wind after noon.

            """)
    }

    // MARK: The store

    private func notesFolder(_ datastore: DataPersistenceManager) -> URL { datastore.aerodromeNotesDirectory }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    func testSavingWritesOneFileNamedAfterTheAerodrome() async {
        let datastore = makeTestDatastore()
        let store = AerodromeNoteStore(persistence: datastore)
        await store.reload()
        await store.save(arrival: "Ask early.", onTheGround: "", for: grenchen)?.value
        let names = files(in: notesFolder(datastore))
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("LSZG_"), names[0])
        XCTAssertEqual(store.note(for: grenchen)?.arrival, "Ask early.")

        // A second store on the same datastore (a relaunch) reads it.
        let relaunched = AerodromeNoteStore(persistence: datastore)
        await relaunched.reload()
        XCTAssertEqual(relaunched.notes.map(\.arrival), ["Ask early."])
        XCTAssertEqual(relaunched.notes.first?.editedOn, AerodromeNoteStore.deviceKind)
    }

    func testANoteEmptiedIsDeletedAndRecorded() async {
        let datastore = makeTestDatastore()
        let store = AerodromeNoteStore(persistence: datastore)
        await store.reload()
        await store.save(arrival: "Ask early.", onTheGround: "", for: grenchen)?.value
        let id = try! XCTUnwrap(store.note(for: grenchen)).id
        XCTAssertNil(store.save(arrival: "  ", onTheGround: "\n", for: grenchen))
        XCTAssertNil(store.note(for: grenchen))
        XCTAssertTrue(files(in: notesFolder(datastore)).isEmpty)
        XCTAssertNotNil(datastore.deletionMark(.aerodromeNote, id: id))
    }

    func testANoteFollowsItsAerodromeRenamedInTheData() async {
        let datastore = makeTestDatastore()
        let store = AerodromeNoteStore(persistence: datastore)
        await store.reload()
        let old = AerodromeRef(ident: "CH-0002", name: "Hasenstrick", latitude: 47.29, longitude: 8.86)
        await store.save(arrival: "Short strip.", onTheGround: "", for: old)?.value
        let renamed = AerodromeRef(ident: "LSYQ", name: "Hasenstrick", latitude: 47.29, longitude: 8.86,
                                   otherIdents: ["CH-0002"])
        await store.save(arrival: "Short strip, uphill.", onTheGround: "", for: renamed)?.value
        let names = files(in: notesFolder(datastore))
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("LSYQ_"), names[0])
        XCTAssertEqual(store.notes.count, 1)
    }

    func testDeleteAllRemovesEveryFile() async {
        let datastore = makeTestDatastore()
        let store = AerodromeNoteStore(persistence: datastore)
        await store.reload()
        await store.save(arrival: "a", onTheGround: "", for: grenchen)?.value
        await store.save(arrival: "b", onTheGround: "", for: AerodromeRef(ident: "LSPL", name: "Langenthal",
                                                                         latitude: 47.18, longitude: 7.74))?.value
        store.deleteAll()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(files(in: notesFolder(datastore)).isEmpty)
        await store.reload()
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testTwoFilesOnOneAerodromeAreMadeOneAtLoad() async {
        // Two devices each wrote a note on Grenchen before iCloud brought them together.
        let datastore = makeTestDatastore()
        let older = note(arrival: "Gliders at weekends.", updated: 100)
        let newer = note(arrival: "Ask early.", updated: 200)
        DataPersistenceManager.writeAerodromeNoteFiles([older, newer], to: notesFolder(datastore))
        XCTAssertEqual(files(in: notesFolder(datastore)).count, 2)
        let store = AerodromeNoteStore(persistence: datastore)
        await store.reload()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].arrival, "Ask early.\n\nGliders at weekends.")
        XCTAssertEqual(files(in: notesFolder(datastore)).count, 1)
        XCTAssertNotNil(datastore.deletionMark(.aerodromeNote, id: older.id))
    }

    func testANoteDeletedOnAnotherDeviceIsLeftOutAtLoad() async {
        let datastore = makeTestDatastore()
        let deleted = note(arrival: "Gone.", updated: 100)
        DataPersistenceManager.writeAerodromeNoteFiles([deleted], to: notesFolder(datastore))
        datastore.recordDeletion(.aerodromeNote, id: deleted.id, stamp: deleted.updatedAt,
                                 at: Date(timeIntervalSince1970: 150))
        let store = AerodromeNoteStore(persistence: datastore)
        await store.reload()
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testSearchReadsInsideTheNotes() async {
        let store = AerodromeNoteStore(persistence: makeTestDatastore())
        await store.reload()
        await store.save(arrival: "", onTheGround: "Restaurant open every day.", for: grenchen)?.value
        XCTAssertEqual(store.notes(matching: "restaurant").map(\.ident), ["LSZG"])
        XCTAssertEqual(store.notes(matching: "grench").map(\.ident), ["LSZG"])
        XCTAssertTrue(store.notes(matching: "samedan").isEmpty)
        XCTAssertEqual(store.notes(matching: "").count, 1)
    }

    // MARK: "Sync to iCloud": the notes move with the store

    func testTheSwitchCopiesTheNotesFolderAndKeepsDeletedOnesOut() throws {
        let fm = FileManager.default
        let root = makeTestDirectory()
        let local = root.appendingPathComponent("local"), cloud = root.appendingPathComponent("cloud")
        let retired = root.appendingPathComponent("retired")
        let folder = DataPersistenceManager.aerodromeNotesFolderName
        let kept = note(arrival: "Kept.", updated: 100)
        let deleted = note("LSPL", name: "Langenthal", arrival: "Deleted.", updated: 100)
        DataPersistenceManager.writeAerodromeNoteFiles([kept, deleted], to: local.appendingPathComponent(folder))
        DeletionRecords.write(.aerodromeNote, id: deleted.id, deletedAt: Date(timeIntervalSince1970: 150), storeRoot: local)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)

        _ = DataPersistenceManager.mergeDatastore(from: local, into: cloud, retiringInto: retired, fileManager: fm)

        let names = files(in: cloud.appendingPathComponent(folder))
        XCTAssertEqual(names, [DataPersistenceManager.aerodromeNoteFilename(for: kept)])
        XCTAssertEqual(DataPersistenceManager.deletionKind(ofFolder: folder), .aerodromeNote)
    }
}
