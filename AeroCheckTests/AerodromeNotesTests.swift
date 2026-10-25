import XCTest
import CoreLocation
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

    /// Markdown's headings in a plain text file: the aerodromes, the parts and the notes stand apart
    /// (the author's device check n-9).
    func testTheExportListsEachNoteByAerodromeWithItsParts() {
        let text = AerodromeNoteExport.text(
            [note("LSZS", name: "Samedan", arrival: "Valley wind after noon."),
             note("LSZG", arrival: "Ask early.", ground: "Fuel at the pump.\nCafé closed Mondays."),
             note("LSPL", name: "Langenthal")],
            arrivalTitle: "Arrival", groundTitle: "On the ground", header: "AéroCheck · Aerodrome notes · 25 Oct 2026")
        XCTAssertEqual(text, """
            # AéroCheck · Aerodrome notes · 25 Oct 2026

            ## LSZG Grenchen

            ### Arrival
            Ask early.

            ### On the ground
            Fuel at the pump.
            Café closed Mondays.

            ## LSZS Samedan

            ### Arrival
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

    // MARK: Where notes show

    private func airport(_ ident: String, _ lat: Double, _ lon: Double) -> Airport {
        Airport(id: abs(ident.hashValue % 100_000), ident: ident, type: .smallAirport, name: ident + " field",
                latitude: lat, longitude: lon, elevation: 1_400, continent: "EU", isoCountry: "CH", isoRegion: "CH-NE",
                municipality: nil, scheduledService: false, gpsCode: ident, iataCode: nil, localCode: nil)
    }

    func testTheFlightsAerodromesAreItsEndsItsStopsAndItsAerodromesEachOnce() {
        let known = ["LSZQ": airport("LSZQ", 47.39, 7.03), "LSZP": airport("LSZP", 47.03, 7.40),
                     "LSZG": airport("LSZG", 47.18, 7.42)]
        var stop = FlightPlanWaypoint(name: "LSZP", coordinate: .init(latitude: 47.03, longitude: 7.40))
        stop.stopover = Stopover()
        let plan = FlightPlan(name: "Trip", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.39, longitude: 7.03)),
            FlightPlanWaypoint(name: "BENOT", coordinate: .init(latitude: 47.3, longitude: 7.2), pointKind: .vrp),
            stop,
            FlightPlanWaypoint(name: "Grenchen", coordinate: .init(latitude: 47.18, longitude: 7.42),
                               pointKind: .aerodrome, sourceId: "LSZG"),
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.39, longitude: 7.03)),
        ])
        let refs = AerodromeRef.flightAerodromes(of: plan) { known[$0] }
        XCTAssertEqual(refs.map(\.ident), ["LSZQ", "LSZP", "LSZG"])
        XCTAssertTrue(AerodromeRef.flightAerodromes(of: nil) { known[$0] }.isEmpty)
    }

    func testTheSearchAddsTheAerodromesWhoseNoteHoldsTheWordsOnce() {
        let grenchenField = airport("LSZG", 47.18, 7.42), bern = airport("LSZB", 46.91, 7.50)
        let notes = [note(ground: "Restaurant open every day."), note("LSZB", name: "Bern", ground: "Restaurant.")]
        let found = AirfieldSearch.adding(noteMatchesFor: "restaurant", to: [bern], notes: notes, near: nil,
                                          find: { ["LSZG": grenchenField, "LSZB": bern][$0] })
        XCTAssertEqual(found.map(\.ident), ["LSZB", "LSZG"])
        // Under the search's minimum length, nothing is added.
        XCTAssertEqual(AirfieldSearch.adding(noteMatchesFor: "r", to: [], notes: notes, near: nil,
                                             find: { _ in grenchenField }), [])
    }

    /// The author's answer q-1 (C): from the map's centre, the nearest first, whether the code, the
    /// name or the note found it.
    func testTheSearchListsEverythingNearestFirst() {
        let porrentruy = CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03)
        let bern = airport("LSZB", 46.91, 7.50), grenchenField = airport("LSZG", 47.18, 7.42),
            courtelary = airport("LSZJ", 47.18, 7.04)
        let found = AirfieldSearch.adding(noteMatchesFor: "fuel", to: [bern, courtelary],
                                          notes: [note(ground: "Fuel at the pump.")], near: porrentruy,
                                          find: { ["LSZG": grenchenField][$0] })
        XCTAssertEqual(found.map(\.ident), ["LSZJ", "LSZG", "LSZB"])
    }

    /// The author's device check n-6: found by what the ground part says, the row shows that line
    /// and names its part, never the arrival's first line.
    func testTheSearchShowsTheLineItFoundAndItsPart() {
        let written = note(arrival: "Ask early.\nJoin over the lake.", ground: "Fuel at the pump.\nCafé closed on Mondays.")
        XCTAssertEqual(written.line(matching: "cafe")?.part, .onTheGround)
        XCTAssertEqual(written.line(matching: "cafe")?.line, "Café closed on Mondays.")
        XCTAssertEqual(written.line(matching: "LAKE")?.part, .arrival)
        XCTAssertEqual(written.line(matching: "LAKE")?.line, "Join over the lake.")
        XCTAssertNil(written.line(matching: "Grenchen"), "found by its name: the row shows the first line")
        XCTAssertNil(written.line(matching: "  "))
        // Far into a long line, the line starts a little before the words, after "…".
        let long = note(ground: "Parking on the grass east of the tower, keys at the office, and the fuel card in the drawer.")
        let snippet = long.line(matching: "drawer")?.line ?? ""
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
        XCTAssertTrue(snippet.hasSuffix("in the drawer."), snippet)
        XCTAssertLessThan(snippet.count, 50, snippet)
    }

    func testTheCalloutOffersANoteOnTheGroundOnlyAndReadsOneInFlight() {
        let field = airport("LSZG", 47.18, 7.42)
        let written = note(arrival: "Ask early.")
        func button(in view: UIView?) -> UIButton? { (view as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UIButton }.first }
        let ground = AerodromeNoteCallout.detailView(airport: field, frequencyLines: nil, note: nil, inFlight: false,
                                                     metrics: .ground, tint: .systemBlue, onOpen: {})
        XCTAssertEqual(button(in: ground)?.accessibilityIdentifier, "callout.note.add")
        let flying = AerodromeNoteCallout.detailView(airport: field, frequencyLines: nil, note: nil, inFlight: true,
                                                     metrics: .ground, tint: .systemBlue, onOpen: {})
        XCTAssertNil(flying, "no note is started in flight")
        let reading = AerodromeNoteCallout.detailView(airport: field, frequencyLines: "TWR 120.105", note: written,
                                                      inFlight: true, metrics: .ground, tint: .systemBlue, onOpen: {})
        XCTAssertEqual(button(in: reading)?.accessibilityIdentifier, "callout.note.open")
        XCTAssertEqual((reading as? UIStackView)?.arrangedSubviews.count, 3)
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
