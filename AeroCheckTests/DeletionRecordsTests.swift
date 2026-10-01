import CoreLocation
import XCTest
@testable import AeroCheck

/// Deletion records (6.1): one small file per item the pilot deleted, in the store's `.Deletions`
/// folder, so a copy in the other store (or one a plain copy puts back) stays deleted. A copy is dead
/// when its content stamp is not later than the record's `deletedAt`; a later edit wins.
///
/// The record itself, where it is written, the loaders, the managers, pruning and the import. The
/// switch's merge with records is in `SyncSwitchDatastoreTests`. Everything runs on plain directories
/// (a stand-in for the iCloud Drive container) and test managers: `.shared` is the simulator app's
/// real datastore.
@MainActor
final class DeletionRecordsTests: XCTestCase {

    private let fm = FileManager.default
    private var local: URL!
    private var cloud: URL!
    private var preferences: UserDefaults!

    override func setUpWithError() throws {
        let base = makeTestDirectory()
        local = base.appendingPathComponent("AppSupport", isDirectory: true)
        cloud = base.appendingPathComponent("Container/Documents", isDirectory: true)
        preferences = makeTestDefaults()
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    private func datastore() -> DataPersistenceManager {
        DataPersistenceManager(rootDirectory: local, iCloudDocumentsDirectory: cloud, preferences: preferences)
    }

    private var retired: URL { local.appendingPathComponent(DeletionRecords.retiredFolderName) }

    /// Whole seconds, as the files store them.
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func records(in store: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: DeletionRecords.folder(in: store).path)) ?? [])
    }

    private func retiredFiles(_ kind: DeletionRecord.Kind) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: retired.appendingPathComponent(kind.rawValue).path)) ?? []).sorted()
    }

    private func files(in folder: String, of store: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: store.appendingPathComponent(folder).path)) ?? [])
    }

    /// Fails when the condition never holds: a silent timeout would let a negative assertion after it
    /// pass for the wrong reason.
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if !condition() { XCTFail("timed out waiting", file: file, line: line) }
    }

    private func flight(modified: TimeInterval) -> Flight {
        var flight = Flight(airplane: "wt9-dynamic", startTime: base.addingTimeInterval(-3_600),
                            stopTime: base.addingTimeInterval(-600))
        flight.modifiedAt = base.addingTimeInterval(modified)
        return flight
    }

    private func plan(_ name: String, updated: TimeInterval) -> FlightPlan {
        FlightPlan(name: name,
                   waypoints: [FlightPlanWaypoint(name: "LSZQ", coordinate: CLLocationCoordinate2D(latitude: 46.6, longitude: 7.3)),
                               FlightPlanWaypoint(name: "LSGY", coordinate: CLLocationCoordinate2D(latitude: 46.8, longitude: 6.6))],
                   createdAt: base, updatedAt: base.addingTimeInterval(updated))
    }

    private func savedTrips(_ store: DataPersistenceManager) -> [Trip]? {
        (try? Data(contentsOf: store.tripsFileURL)).flatMap(DataPersistenceManager.decodeTrips)
    }

    private func page(_ label: String, updated: TimeInterval) -> FlightThread {
        var page = FlightThread(routeLabel: label)
        page.createdAt = base
        page.updatedAt = base.addingTimeInterval(updated)
        return page
    }

    private func trip(_ name: String, updated: TimeInterval) -> Trip {
        var trip = Trip(legIds: [UUID(), UUID()])
        trip.name = name
        trip.createdAt = base
        trip.updatedAt = base.addingTimeInterval(updated)
        return trip
    }

    // MARK: - The record

    func testARecordRoundTrips() throws {
        let id = UUID()
        let deletedAt = base.addingTimeInterval(0.7)

        XCTAssertTrue(DeletionRecords.write(.flight, id: id, deletedAt: deletedAt, storeRoot: cloud))

        let name = "flight_\(id.uuidString).json"
        XCTAssertEqual(records(in: cloud), [name])
        let url = DeletionRecords.folder(in: cloud).appendingPathComponent(name)
        let record = try XCTUnwrap(DeletionRecords.readRecord(at: url, now: base))
        XCTAssertEqual(record.v, 1)
        XCTAssertEqual(record.knownKind, .flight)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.deletedAt, base, "ISO 8601 in whole seconds, like the other files")
        let json = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(json.contains("\"kind\":\"flight\""), json)
        XCTAssertLessThan(json.utf8.count, 200)
        XCTAssertEqual(DeletionRecords.read(storeRoot: cloud, now: base).mark(.flight, id: id)?.deletedAt, base)
    }

    func testTheFolderIsHidden() {
        XCTAssertTrue(DeletionRecords.folderName.hasPrefix("."), "a visible folder in Files invites a clean-up")
    }

    /// Every failure to read a record means "no record": an item may come back, never disappear.
    func testWhatIsNotAUsableRecordIsIgnored() throws {
        let folder = DeletionRecords.folder(in: cloud)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func put(_ text: String, _ name: String) throws {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let (unknownKind, garbage, oversize, future, mismatched, good) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
        try put(#"{"v":1,"kind":"aircraft","id":"\#(unknownKind)","deletedAt":"2026-05-28T10:00:00Z"}"#,
                "flight_\(unknownKind).json")
        try put(#"{"v":1,"kind":"aircraft","id":"\#(unknownKind)","deletedAt":"2026-05-28T10:00:00Z"}"#,
                "aircraft_\(unknownKind).json")
        try put("not a record", "plan_\(garbage).json")
        try put(#"{"v":1,"kind":"thread","id":"\#(oversize)","deletedAt":"2026-05-28T10:00:00Z","pad":"\#(String(repeating: "x", count: 5_000))"}"#,
                "thread_\(oversize).json")
        try put(#"{"v":1,"kind":"trip","id":"\#(future)","deletedAt":"2026-06-01T10:00:00Z"}"#, "trip_\(future).json")
        try put(#"{"v":1,"kind":"flight","id":"\#(UUID())","deletedAt":"2026-05-28T10:00:00Z"}"#,
                "flight_\(mismatched).json")
        try put(#"{"v":1,"kind":"flight","id":"\#(good)","deletedAt":"2026-05-28T10:00:00Z"}"#, "flight_\(good).json")
        try put("{}", "notes.txt")

        // 2026-05-29: the "future" record sits three days ahead, beyond the 24 h a clock may be off.
        let ledger = DeletionRecords.read(storeRoot: cloud, now: ISO8601DateFormatter().date(from: "2026-05-29T10:00:00Z")!)

        XCTAssertEqual(ledger.marks.keys.map(\.id), [good])
    }

    /// iCloud evicts files, these too. Its name still says what was deleted; its date waits for the
    /// download: such a copy is neither copied nor retired.
    func testAnEvictedRecordReadsAsDeletedDateUnknown() throws {
        let id = UUID()
        let folder = DeletionRecords.folder(in: cloud)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".plan_\(id.uuidString).json.icloud"))

        let ledger = DeletionRecords.read(storeRoot: cloud)

        XCTAssertEqual(ledger.mark(.plan, id: id), DeletionLedger.Mark(deletedAt: nil, undated: true))
        XCTAssertEqual(ledger.verdict(.plan, id: id, stamp: base), .unknown)
        XCTAssertEqual(ledger.verdict(.plan, id: UUID(), stamp: base), .alive)
    }

    func testTheRuleInWholeSecondsAndALaterEditWins() {
        let deletedAt = base.addingTimeInterval(0.9)
        XCTAssertTrue(DeletionRecords.isDead(stamp: base.addingTimeInterval(-60), deletedAt: deletedAt))
        XCTAssertTrue(DeletionRecords.isDead(stamp: base.addingTimeInterval(0.2), deletedAt: deletedAt),
                      "the file of an item edited and deleted in the same second reads as dead, like memory's copy")
        XCTAssertFalse(DeletionRecords.isDead(stamp: base.addingTimeInterval(1.1), deletedAt: deletedAt))
        let after = DeletionRecords.stamp(after: deletedAt, now: base)
        XCTAssertFalse(DeletionRecords.isDead(stamp: after, deletedAt: deletedAt))
        XCTAssertFalse(DeletionRecords.isDead(stamp: Date(timeIntervalSince1970: after.timeIntervalSince1970.rounded(.down)),
                                              deletedAt: deletedAt), "still later once written in whole seconds")
    }

    func testALaterRecordIsNeverReplacedByAnOlderOne() {
        let id = UUID()
        DeletionRecords.write(.trip, id: id, deletedAt: base.addingTimeInterval(60), storeRoot: cloud)
        DeletionRecords.write(.trip, id: id, deletedAt: base, storeRoot: cloud)
        XCTAssertEqual(DeletionRecords.read(storeRoot: cloud, now: base).mark(.trip, id: id)?.deletedAt,
                       base.addingTimeInterval(60))

        DeletionRecords.write(.trip, id: id, deletedAt: base.addingTimeInterval(120), storeRoot: cloud)
        XCTAssertEqual(DeletionRecords.read(storeRoot: cloud, now: base).mark(.trip, id: id)?.deletedAt,
                       base.addingTimeInterval(120))
    }

    func testOnlyNamesThatCouldHoldARecordedItemAreOpened() {
        let id = UUID()
        let prefixes: Set<String> = [String(id.uuidString.prefix(8))]
        XCTAssertTrue(DeletionRecords.needsProbe("20260928-1000_HB-KFD_\(id.uuidString.prefix(8)).json", prefixes: prefixes))
        XCTAssertFalse(DeletionRecords.needsProbe("20260928-1000_HB-KFD_0BADF00D.json", prefixes: prefixes))
        XCTAssertTrue(DeletionRecords.needsProbe("20260928-1000_HB-KFD.json", prefixes: prefixes), "pre-PR-19 name")
        XCTAssertTrue(DeletionRecords.needsProbe("20260928-1000_Bern_Sion.json", prefixes: prefixes), "pre-6.1 plan")
        XCTAssertFalse(DeletionRecords.needsProbe("plans_index.txt", prefixes: prefixes))
    }

    // MARK: - Written where the pilot deletes, in the store in use

    func testTheFourIntentSitesRecordIntoTheStoreInUse() async throws {
        let store = datastore()
        for on in [true, false] {
            store.setUsesICloudDrive(on)
            let (active, other) = on ? (cloud!, local!) : (local!, cloud!)
            let appState = makeTestAppState(datastore: store)
            let plans = makeTestPlanManager(datastore: store)
            let threads = makeTestThreadManager(datastore: store)
            try await waitUntil { plans.hasLoadedPlans && threads.hasLoadedThreads && !appState.isLoadingFlights }

            // The Logbook.
            let logged = flight(modified: 0)
            XCTAssertTrue(store.saveFlight(logged))
            appState.flights.insert(logged, at: 0)
            appState.deleteFlight(logged)
            // Routes, "Cancel flight".
            let route = plans.createFlightPlan(name: "Route")
            plans.deleteFlightPlan(route)
            // A flight page, and a trip dissolved when a leg goes.
            let lone = threads.createThread(from: nil, routeLabel: "LSZQ → LSGY")
            threads.deleteThread(threadId: lone.id)
            let first = threads.createThread(from: nil, routeLabel: "LSZQ → LFSB")
            let second = threads.createThread(from: nil, routeLabel: "LFSB → LSGY")
            let formed = try XCTUnwrap(threads.formTrip(from: [first.id, second.id]))
            threads.removeLeg(threadId: second.id)

            let expected: Set<String> = [
                "flight_\(logged.id.uuidString).json", "plan_\(route.id.uuidString).json",
                "thread_\(lone.id.uuidString).json", "thread_\(second.id.uuidString).json",
                "trip_\(formed.id.uuidString).json",
            ]
            XCTAssertTrue(records(in: active).isSuperset(of: expected), "switch \(on ? "on" : "off"): \(records(in: active))")
            XCTAssertTrue(records(in: other).isDisjoint(with: expected), "never in the store not in use")
            XCTAssertNil(threads.trip(withId: formed.id))
            XCTAssertFalse(records(in: active).contains("thread_\(first.id.uuidString).json"), "the survivor lives on")
        }
    }

    /// The file deletes that tidy up after a rename, and the CloudKit ingest's, remove files of items
    /// that live on: a record there would later kill the real copy in the other store.
    func testRenamesRelabelsAndTheCloudKitIngestRecordNothing() async throws {
        let store = datastore()
        let plans = makeTestPlanManager(datastore: store)
        let threads = makeTestThreadManager(datastore: store)
        try await waitUntil { plans.hasLoadedPlans && threads.hasLoadedThreads }

        let route = plans.createFlightPlan(name: "Before")
        try await waitUntil { !self.files(in: "NavigationPlans", of: self.cloud).filter { $0.contains("Before") }.isEmpty }
        plans.rename(route, to: "After")
        try await waitUntil { self.files(in: "NavigationPlans", of: self.cloud).filter { $0.contains("Before") }.isEmpty }

        let page = threads.createThread(from: nil, routeLabel: "LSZQ → LSGY")
        try await waitUntil { self.files(in: "FlightThreads", of: self.cloud).contains { $0.contains("LSZQ") } }
        threads.updateRouteLabel("LSZQ → LSZB", threadId: page.id)
        try await waitUntil { !self.files(in: "FlightThreads", of: self.cloud).contains { $0.contains("LSGY") } }

        let backend = StubSyncBackend()
        let syncDefaults = makeTestDefaults()
        let sync = SyncManager(defaults: syncDefaults, backend: backend)
        let (kept, removedElsewhere) = (flight(modified: 0), flight(modified: 10))
        XCTAssertTrue(store.saveFlight(kept))
        XCTAssertTrue(store.saveFlight(removedElsewhere))
        let appState = makeTestAppState(datastore: store, syncManager: sync)
        try await waitUntil { appState.flights.count == 2 }
        await sync.onFlightsUpdated?([kept])
        XCTAssertFalse(files(in: "Flights", of: cloud).contains(DataPersistenceManager.flightFilename(for: removedElsewhere)))

        XCTAssertTrue(records(in: cloud).isEmpty, "\(records(in: cloud))")
        XCTAssertTrue(records(in: local).isEmpty)
    }

    // MARK: - The loaders

    private func write(_ plan: FlightPlan, in store: URL) {
        let folder = store.appendingPathComponent("NavigationPlans", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        DataPersistenceManager.writeNavigationPlanFiles([plan], index: [plan], to: folder)
    }

    private func write(_ page: FlightThread, in store: URL) {
        let folder = store.appendingPathComponent("FlightThreads", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        DataPersistenceManager.writeFlightThreadFiles([page], to: folder)
    }

    /// A dead file put back by a plain copy (an older build switching, a backup restored): the loader
    /// leaves it out and retires it, which is what makes every device converge. A copy edited after
    /// the deletion, or one only an undated record covers, loads.
    func testTheLoadersRetireADeadFileAndKeepTheRest() async throws {
        let store = datastore()
        let (deadFlight, liveFlight) = (flight(modified: 0), flight(modified: 0))
        let (deadPlan, editedPlan, undatedPlan) = (plan("Dead", updated: 0), plan("Edited", updated: 120), plan("Undated", updated: 0))
        let (deadPage, livePage) = (page("LSZQ → LSGY", updated: 0), page("LSGY → LSZQ", updated: 0))
        for item in [deadFlight, liveFlight] { XCTAssertTrue(store.saveFlight(item)) }
        for item in [deadPlan, editedPlan, undatedPlan] { write(item, in: cloud) }
        for item in [deadPage, livePage] { write(item, in: cloud) }
        let deletedAt = base.addingTimeInterval(60)
        DeletionRecords.write(.flight, id: deadFlight.id, deletedAt: deletedAt, storeRoot: cloud)
        DeletionRecords.write(.plan, id: deadPlan.id, deletedAt: deletedAt, storeRoot: cloud)
        DeletionRecords.write(.plan, id: editedPlan.id, deletedAt: deletedAt, storeRoot: cloud)
        DeletionRecords.write(.thread, id: deadPage.id, deletedAt: deletedAt, storeRoot: cloud)
        try Data().write(to: DeletionRecords.folder(in: cloud).appendingPathComponent(".plan_\(undatedPlan.id.uuidString).json.icloud"))

        let flights = await store.loadFlightsOffMain()
        let plans = await store.loadNavigationPlansOffMain()
        let pages = await store.loadFlightThreadsOffMain()

        XCTAssertEqual(flights.map(\.id), [liveFlight.id])
        XCTAssertEqual(Set(plans.map(\.id)), [editedPlan.id, undatedPlan.id])
        XCTAssertEqual(pages.map(\.id), [livePage.id])
        XCTAssertEqual(retiredFiles(.flight), [DataPersistenceManager.flightFilename(for: deadFlight)])
        XCTAssertEqual(retiredFiles(.plan), [DataPersistenceManager.navigationPlanFilename(for: deadPlan)])
        XCTAssertEqual(retiredFiles(.thread), [DataPersistenceManager.flightThreadFilename(for: deadPage)])
        XCTAssertEqual(files(in: "Flights", of: cloud), [DataPersistenceManager.flightFilename(for: liveFlight)])
        XCTAssertEqual(records(in: cloud).count, 5, "the records stay")
        let synchronous = store.loadFlights()
        XCTAssertEqual(synchronous.map(\.id), [liveFlight.id])
    }

    /// Trips live in one file: a load drops the dissolved ones and writes nothing; the next trip save
    /// writes what is live.
    func testTheTripsLoaderDropsADissolvedTripAndWritesNothing() async throws {
        let store = datastore()
        let (dissolved, kept, editedSince) = (trip("dissolved", updated: 0), trip("kept", updated: 0), trip("edited", updated: 120))
        try DataPersistenceManager.encodeTrips([dissolved, kept, editedSince]).write(to: store.tripsFileURL)
        let onDisk = try Data(contentsOf: store.tripsFileURL)
        DeletionRecords.write(.trip, id: dissolved.id, deletedAt: base.addingTimeInterval(60), storeRoot: cloud)
        DeletionRecords.write(.trip, id: editedSince.id, deletedAt: base.addingTimeInterval(60), storeRoot: cloud)

        let loaded = await store.loadTripsOffMain()

        XCTAssertEqual(Set(loaded.map(\.id)), [kept.id, editedSince.id])
        XCTAssertEqual(try Data(contentsOf: store.tripsFileURL), onDisk, "a load writes nothing")

        await store.saveTripsOffMain([dissolved, kept, editedSince])
        let saved = try XCTUnwrap(DataPersistenceManager.decodeTrips(Data(contentsOf: store.tripsFileURL)))
        XCTAssertEqual(Set(saved.map(\.id)), [kept.id, editedSince.id])
    }

    // MARK: - The managers

    /// A device that has not reloaded since another one dissolved a trip still holds it; its next trip
    /// save used to write it back with the rest.
    func testATripSaveNeverWritesADissolvedTrip() async throws {
        let store = datastore()
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        let legs = (0..<4).map { manager.createThread(from: nil, routeLabel: "LEG \($0)") }
        let dissolvedElsewhere = try XCTUnwrap(manager.formTrip(from: [legs[0].id, legs[1].id]))
        let other = try XCTUnwrap(manager.formTrip(from: [legs[2].id, legs[3].id]))
        try await waitUntil { self.savedTrips(store)?.count == 2 }
        DeletionRecords.write(.trip, id: dissolvedElsewhere.id, deletedAt: Date().addingTimeInterval(1), storeRoot: cloud)

        manager.renameTrip(other.id, to: "Tour")

        try await waitUntil { self.savedTrips(store)?.first?.name == "Tour" }
        let saved = try XCTUnwrap(savedTrips(store))
        XCTAssertEqual(saved.map(\.id), [other.id])
    }

    /// After a move, memory holds the old store's items. One the new store's records say is dead
    /// leaves memory, with its `lastPersisted`: its next save would have written it back there.
    func testAfterAMoveTheManagersDropWhatTheNewStoreDeleted() async throws {
        let store = datastore()
        let deadPlan = plan("Deleted while off", updated: 0)
        let livePlan = plan("Kept", updated: 0)
        let deadPage = page("LSZQ → LSGY", updated: 0)
        let livePage = page("LSGY → LSZQ", updated: 0)
        var dissolved = trip("dissolved while off", updated: 0)
        dissolved.legIds = [UUID(), UUID()]
        let keptTrip = trip("kept", updated: 0)
        for item in [deadPlan, livePlan] { write(item, in: cloud) }
        for item in [deadPage, livePage] { write(item, in: cloud) }
        try DataPersistenceManager.encodeTrips([dissolved, keptTrip]).write(to: cloud.appendingPathComponent("trips.json"))
        let plans = makeTestPlanManager(datastore: store)
        let threads = makeTestThreadManager(datastore: store)
        try await waitUntil { plans.hasLoadedPlans && threads.hasLoadedThreads }
        XCTAssertEqual(plans.flightPlans.count, 2)
        XCTAssertEqual(threads.threads.count, 2)
        XCTAssertEqual(threads.trips.count, 2)
        // Deleted in the local store during an earlier off period (or by another device on it).
        let deletedAt = base.addingTimeInterval(60)
        DeletionRecords.write(.plan, id: deadPlan.id, deletedAt: deletedAt, storeRoot: local)
        DeletionRecords.write(.thread, id: deadPage.id, deletedAt: deletedAt, storeRoot: local)
        DeletionRecords.write(.trip, id: dissolved.id, deletedAt: deletedAt, storeRoot: local)
        let marker = plan("Only here", updated: 0)
        write(marker, in: local)

        store.setUsesICloudDrive(false)

        try await waitUntil { plans.flightPlans.contains { $0.id == marker.id } && threads.trips.count == 1 }
        try await waitUntil { threads.threads.count == 1 }
        XCTAssertEqual(Set(plans.flightPlans.map(\.id)), [livePlan.id, marker.id])
        XCTAssertEqual(threads.threads.map(\.id), [livePage.id])
        XCTAssertEqual(threads.trips.map(\.id), [keptTrip.id])

        // Their `lastPersisted` went with them: the next saves write the live items only.
        plans.rename(livePlan, to: "Kept, renamed")
        threads.renameFlight(livePage.id, to: "Renamed")
        try await waitUntil { self.files(in: "NavigationPlans", of: self.local).contains { $0.contains("Kept,_renamed") } }
        try await waitUntil { DataPersistenceManager.decodeFlightThreads(in: self.local.appendingPathComponent("FlightThreads")).contains { $0.name == "Renamed" } }
        XCTAssertFalse(DataPersistenceManager.decodeNavigationPlans(in: local.appendingPathComponent("NavigationPlans"))
            .contains { $0.id == deadPlan.id })
        XCTAssertFalse(DataPersistenceManager.decodeFlightThreads(in: local.appendingPathComponent("FlightThreads"))
            .contains { $0.id == deadPage.id })
    }

    private func activePlanAfterAMove(flying: Bool) async throws -> (manager: FlightPlanManager, plan: FlightPlan) {
        let store = datastore()
        let route = plan("Being flown", updated: 0)
        write(route, in: cloud)
        let manager = makeTestPlanManager(datastore: store)
        manager.isFlightInProgress = { flying }
        try await waitUntil { manager.hasLoadedPlans }
        manager.activateFlightPlan(try XCTUnwrap(manager.flightPlans.first))
        XCTAssertEqual(manager.activeFlightPlan?.id, route.id)
        // Deleted on another device, on the local store, before this device switches off.
        DeletionRecords.write(.plan, id: route.id, deletedAt: base.addingTimeInterval(60), storeRoot: local)
        let marker = plan("Only here", updated: 0)
        write(marker, in: local)

        store.setUsesICloudDrive(false)

        try await waitUntil { manager.flightPlans.contains { $0.id == marker.id } }
        return (manager, route)
    }

    func testAPlanDeletedElsewhereComesOffTheMapOnTheGround() async throws {
        let (manager, route) = try await activePlanAfterAMove(flying: false)

        XCTAssertNil(manager.activeFlightPlan)
        XCTAssertFalse(manager.flightPlans.contains { $0.id == route.id })
    }

    /// The flight is using it: an edit later than the deletion.
    func testThePlanBeingFlownSurvivesItsDeletionElsewhere() async throws {
        let (manager, route) = try await activePlanAfterAMove(flying: true)

        let active = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertEqual(active.id, route.id)
        XCTAssertTrue(manager.flightPlans.contains { $0.id == route.id })
        XCTAssertFalse(DeletionRecords.isDead(stamp: active.updatedAt, deletedAt: base.addingTimeInterval(60)))
        try await waitUntil {
            DataPersistenceManager.decodeNavigationPlans(in: self.local.appendingPathComponent("NavigationPlans"))
                .contains { $0.id == route.id }
        }
        let onDisk = DataPersistenceManager.decodeNavigationPlans(in: local.appendingPathComponent("NavigationPlans"),
                                                                  deletions: DeletionFilter.reading(storeRoot: local, retiredRoot: retired,
                                                                                                    kinds: [.plan]))
        XCTAssertTrue(onDisk.contains { $0.id == route.id }, "written back, alive")
    }

    /// The same for a flight page: one being flown keeps its copy.
    func testAPageBeingFlownSurvivesItsDeletionElsewhere() async throws {
        let store = datastore()
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        let flying = manager.createThread(from: nil, routeLabel: "LSZQ → LSGY")
        manager.attachFlight(UUID(), toThreadId: flying.id)
        XCTAssertEqual(manager.thread(withId: flying.id)?.state, .flying)
        let stamp = try XCTUnwrap(manager.thread(withId: flying.id)?.updatedAt)
        DeletionRecords.write(.thread, id: flying.id, deletedAt: stamp.addingTimeInterval(1), storeRoot: local)
        let marker = page("only here", updated: 0)
        write(marker, in: local)

        store.setUsesICloudDrive(false)

        try await waitUntil { manager.thread(withId: marker.id) != nil }
        let kept = try XCTUnwrap(manager.thread(withId: flying.id))
        XCTAssertEqual(kept.state, .flying)
        XCTAssertFalse(DeletionRecords.isDead(stamp: kept.updatedAt, deletedAt: stamp.addingTimeInterval(1)))
    }

    // MARK: - Pruning

    func testPruningKeepsRecordsFor400DaysAndRetiredCopiesFor30() throws {
        let now = Date()
        let (old, recent) = (UUID(), UUID())
        DeletionRecords.write(.flight, id: old, deletedAt: now.addingTimeInterval(-401 * 86_400), storeRoot: cloud)
        DeletionRecords.write(.flight, id: recent, deletedAt: now.addingTimeInterval(-399 * 86_400), storeRoot: cloud)
        try Data().write(to: DeletionRecords.folder(in: cloud).appendingPathComponent(".plan_\(UUID().uuidString).json.icloud"))
        let folder = retired.appendingPathComponent("flight", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, age) in [("purged.json", 31.0), ("kept.json", 29.0)] {
            let url = folder.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: url.path)
        }

        let pruned = DeletionRecords.prune(storeRoot: cloud, retiredRoot: retired, now: now)

        XCTAssertEqual(pruned.records, 1)
        XCTAssertEqual(pruned.retired, 1)
        XCTAssertEqual(records(in: cloud).filter { !$0.hasPrefix(".") }, ["flight_\(recent.uuidString).json"])
        XCTAssertEqual(records(in: cloud).count, 2, "an evicted record is left alone")
        XCTAssertEqual(retiredFiles(.flight), ["kept.json"])
    }

    /// Only the store in use: the other keeps its records until it is the one in use.
    func testPruningLeavesTheStoreNotInUseAlone() async throws {
        let old = Date().addingTimeInterval(-500 * 86_400)
        let (inCloud, inLocal) = (UUID(), UUID())
        DeletionRecords.write(.plan, id: inCloud, deletedAt: old, storeRoot: cloud)
        DeletionRecords.write(.plan, id: inLocal, deletedAt: old, storeRoot: local)
        let store = datastore()

        let pruned = await store.pruneDeletionRecordsOffMain()

        XCTAssertEqual(pruned.records, 1)
        XCTAssertTrue(records(in: cloud).isEmpty)
        XCTAssertEqual(records(in: local), ["plan_\(inLocal.uuidString).json"])
    }

    // MARK: - The import

    /// A JSON export keeps the flight's id and `modifiedAt`: imported back after the flight was
    /// deleted, it would have died at the next load. An import is an edit.
    func testTheReimportedExportOfADeletedFlightSurvivesTheNextLoad() async throws {
        let store = datastore()
        let deleted = flight(modified: 0)
        XCTAssertTrue(store.saveFlight(deleted))
        let appState = makeTestAppState(datastore: store)
        try await waitUntil { appState.flights.contains { $0.id == deleted.id } }
        let export = try XCTUnwrap(deleted.toJSON())
        appState.deleteFlight(deleted)
        XCTAssertTrue(records(in: cloud).contains("flight_\(deleted.id.uuidString).json"))

        let imported = try XCTUnwrap(appState.importedFlight(from: export))

        XCTAssertEqual(imported.flight.id, deleted.id)
        let loaded = await store.loadFlightsOffMain()
        XCTAssertEqual(loaded.map(\.id), [deleted.id], "the re-imported flight is alive")
        XCTAssertTrue(retiredFiles(.flight).isEmpty)
        // And through the switch both ways.
        store.setUsesICloudDrive(false)
        store.setUsesICloudDrive(true)
        let afterSwitching = await store.loadFlightsOffMain()
        XCTAssertEqual(afterSwitching.map(\.id), [deleted.id])
    }

    /// Deleted on another device with the switch on, imported back here with it off: the record is
    /// in iCloud Drive only, and the next switch-on would have taken the imported copy for the deleted
    /// one.
    func testAnImportWhileOffOutlivesARecordInTheOtherStore() async throws {
        let store = datastore()
        store.setUsesICloudDrive(false)
        let deleted = flight(modified: 0)
        let export = try XCTUnwrap(deleted.toJSON())
        DeletionRecords.write(.flight, id: deleted.id, deletedAt: base.addingTimeInterval(60), storeRoot: cloud)
        let appState = makeTestAppState(datastore: store)
        try await waitUntil { !appState.isLoadingFlights }

        XCTAssertNotNil(appState.importedFlight(from: export))
        appState.settings.iCloudSyncEnabled = true
        appState.saveSettings()

        let loaded = await store.loadFlightsOffMain()
        XCTAssertEqual(loaded.map(\.id), [deleted.id])
        XCTAssertTrue(retiredFiles(.flight).isEmpty)
    }
}

// MARK: - CloudKit

/// Deletion records (6.1) on CloudKit's side. A flight deleted with the switch off was never sent to
/// CloudKit: it stayed there and on every other device. Now its record becomes a delete owed to
/// CloudKit when it comes up, a fetch cannot bring a deleted flight back, and a delete received from
/// CloudKit leaves a record of its own. A later edit still beats an older delete.
///
/// A `SyncManager` on a defaults suite of its own and the stand-in engine (`StubSyncBackend`), never
/// `.standard` and never real CloudKit; the stores are plain directories.
@MainActor
final class CloudKitDeletionRecordsTests: XCTestCase {

    private let fm = FileManager.default
    private var local: URL!
    private var cloud: URL!
    private var defaults: UserDefaults!
    private var backend: StubSyncBackend!

    /// Whole seconds, as the files store them.
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUpWithError() throws {
        let root = makeTestDirectory()
        local = root.appendingPathComponent("AppSupport", isDirectory: true)
        cloud = root.appendingPathComponent("Container/Documents", isDirectory: true)
        defaults = makeTestDefaults()
        backend = StubSyncBackend()
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    private func manager(on: Bool) -> SyncManager {
        defaults.set(on, forKey: DataPersistenceManager.syncPreferenceKey)
        return SyncManager(defaults: defaults, backend: backend)
    }

    private func started(_ manager: SyncManager) async throws -> StubSyncEngine {
        await manager.engineStartTask?.value
        return try XCTUnwrap(backend.engines.last, "no engine was started")
    }

    private func flight(modified: TimeInterval) -> Flight {
        var flight = Flight(airplane: "wt9-dynamic", startTime: base.addingTimeInterval(-3_600),
                            stopTime: base.addingTimeInterval(-600))
        flight.modifiedAt = base.addingTimeInterval(modified)
        return flight
    }

    private func records(of id: UUID) -> Set<String> {
        [id.uuidString, SyncManager.trackRecordName(id)]
    }

    /// Flights deleted at the given dates (nil: a record iCloud has not downloaded yet).
    private func ledger(_ entries: [(UUID, Date?)]) -> DeletionLedger {
        var ledger = DeletionLedger()
        for (id, deletedAt) in entries { ledger.note(.flight, id: id, deletedAt: deletedAt) }
        return ledger
    }

    /// Record names whose queued delete was taken back.
    private func withdrawnDeletes(_ engine: StubSyncEngine) -> Set<String> {
        Set(engine.unqueued.compactMap { if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil } })
    }

    /// Fails when the condition never holds, so an assertion after it never passes for the wrong reason.
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if !condition() { XCTFail("timed out waiting", file: file, line: line) }
    }

    // MARK: The inbound filter

    /// Deleted here with the switch off, its delete not sent yet: a fetch brings the copy CloudKit
    /// still holds, and it is dropped before the merge. The same second as the deletion counts as
    /// before it, as on disk.
    func testAFetchedCopyNotEditedSinceItsDeletionIsDropped() {
        let deleted = flight(modified: 0)
        let sameSecond = flight(modified: 60.4)
        let unrelated = flight(modified: -600)
        let deletions = ledger([(deleted.id, base.addingTimeInterval(60)), (sameSecond.id, base.addingTimeInterval(60))])

        let result = SyncManager.filterInboundFlights([deleted, sameSecond, unrelated], local: [], deletions: deletions)

        XCTAssertEqual(result.live.map(\.id), [unrelated.id])
        XCTAssertEqual(result.dead, [deleted.id, sameSecond.id])
        XCTAssertTrue(result.revived.isEmpty)
    }

    /// An edit made elsewhere after the deletion, by a device that did not know yet: it wins.
    func testAnEditMadeAfterTheDeletionStillComesThrough() {
        let edited = flight(modified: 61)
        let deletions = ledger([(edited.id, base.addingTimeInterval(60))])

        let result = SyncManager.filterInboundFlights([edited], local: [], deletions: deletions)

        XCTAssertEqual(result.live.map(\.id), [edited.id])
        XCTAssertTrue(result.dead.isEmpty)
        XCTAssertEqual(result.revived, [edited.id])
    }

    /// The track record decodes to a flight too, stamped when the track was last sent: a metadata
    /// edit after the deletion keeps the track with it, and a live copy here keeps the flight.
    func testTheTrackRecordFollowsItsFlightAndALiveCopyHereKeepsIt() {
        let metadata = flight(modified: 120)
        var track = metadata
        track.modifiedAt = base
        let elsewhere = flight(modified: 0)
        var liveHere = elsewhere
        liveHere.modifiedAt = base.addingTimeInterval(120)
        let deletions = ledger([(metadata.id, base.addingTimeInterval(60)), (elsewhere.id, base.addingTimeInterval(60))])

        let result = SyncManager.filterInboundFlights([metadata, track, elsewhere], local: [liveHere], deletions: deletions)

        XCTAssertEqual(result.live.count, 3)
        XCTAssertTrue(result.dead.isEmpty)
    }

    /// A record iCloud has not downloaded yet decides nothing: an item may come back, never vanish.
    func testARecordNotDownloadedYetDropsNothing() {
        let copy = flight(modified: 0)

        let result = SyncManager.filterInboundFlights([copy], local: [], deletions: ledger([(copy.id, nil)]))

        XCTAssertEqual(result.live.map(\.id), [copy.id])
        XCTAssertTrue(result.dead.isEmpty)
        XCTAssertTrue(result.revived.isEmpty)
    }

    /// Through the manager: the dropped copy is still in CloudKit, which is owed its delete; a copy
    /// brought back by a later edit withdraws the delete owed for it, before it is sent.
    func testAFetchApplyingTheRecordsOwesTheDeadAndWithdrawsTheRevived() async throws {
        let manager = manager(on: true)
        let (dead, revived) = (flight(modified: 0), flight(modified: 120))
        let deletions = ledger([(dead.id, base.addingTimeInterval(60)), (revived.id, base.addingTimeInterval(60))])
        manager.flightDeletionRecords = { deletions }
        let engine = try await started(manager)
        manager.deleteFlight(revived.id)
        XCTAssertEqual(manager.owedFlightDeletions, [revived.id])

        let result = await manager.applyingDeletionRecords(toInbound: [dead, revived], local: [])

        XCTAssertEqual(result.live.map(\.id), [revived.id])
        XCTAssertEqual(manager.owedFlightDeletions, [dead.id])
        XCTAssertTrue(engine.deletes.isSuperset(of: records(of: dead.id)))
        XCTAssertEqual(withdrawnDeletes(engine), records(of: revived.id))
    }

    /// The flight comes back (the import of its export, stamped after the record): its save
    /// replaces the delete still owed for it, never goes out in the same batch with it.
    func testASaveOfAFlightOwedADeleteReplacesTheDelete() async throws {
        let manager = manager(on: true)
        let engine = try await started(manager)
        let reimported = flight(modified: 120)
        manager.deleteFlight(reimported.id)

        manager.syncFlight(reimported, allFlights: [reimported])

        XCTAssertTrue(manager.owedFlightDeletions.isEmpty)
        XCTAssertEqual(withdrawnDeletes(engine), records(of: reimported.id))
        XCTAssertEqual(engine.saves, records(of: reimported.id))
    }

    // MARK: Deletes owed when CloudKit comes up

    /// The whole path: a flight CloudKit holds, deleted with the switch off, then the switch back on.
    /// CloudKit gets the delete, and the copy iCloud Drive kept while off is never sent back.
    func testAFlightDeletedWhileOffIsDeletedFromCloudKitWhenTheSwitchComesOn() async throws {
        defaults.set(true, forKey: DataPersistenceManager.syncPreferenceKey)
        let store = DataPersistenceManager(rootDirectory: local, iCloudDocumentsDirectory: cloud, preferences: defaults)
        let doomed = flight(modified: 0)
        XCTAssertTrue(store.saveFlight(doomed))
        let manager = SyncManager(defaults: defaults, backend: backend)
        // Sent with the switch on, and confirmed.
        manager.markFlightSynced(doomed.id, modifiedAt: doomed.modifiedAt)
        manager.markFlightTrackSynced(doomed.id, count: doomed.gpsTrack.count)
        let appState = makeTestAppState(datastore: store, syncManager: manager)
        _ = try await started(manager)
        try await waitUntil { appState.flights.contains { $0.id == doomed.id } }

        appState.settings.iCloudSyncEnabled = false
        appState.saveSettings()
        appState.deleteFlight(doomed)
        XCTAssertTrue(manager.owedFlightDeletions.isEmpty, "off: CloudKit is not touched")
        let cloudCopy = cloud.appendingPathComponent("Flights").appendingPathComponent(DataPersistenceManager.flightFilename(for: doomed))
        XCTAssertTrue(fm.fileExists(atPath: cloudCopy.path), "iCloud Drive keeps its copy while off")

        appState.settings.iCloudSyncEnabled = true
        appState.saveSettings()
        let engine = try await started(manager)

        XCTAssertEqual(backend.engines.count, 2)
        XCTAssertEqual(engine.deletes, records(of: doomed.id))
        XCTAssertTrue(engine.saves.isDisjoint(with: records(of: doomed.id)), "never sent back: \(engine.saves)")
        XCTAssertEqual(manager.owedFlightDeletions, [doomed.id])
        XCTAssertNotNil(DeletionRecords.mark(.flight, id: doomed.id, storeRoot: cloud), "the record followed the store")
        XCTAssertFalse(appState.flights.contains { $0.id == doomed.id })
    }

    /// Owed until CloudKit confirms it: a relaunch sends it again, a confirmation ends it, and the
    /// record, which stays, never makes it owed again.
    func testTheOwedDeleteOutlivesARelaunchAndDrainsOnConfirmation() async throws {
        let doomed = flight(modified: 0)
        let deletions = ledger([(doomed.id, base.addingTimeInterval(60))])
        func launch() -> SyncManager {
            let manager = SyncManager(defaults: defaults, backend: backend)
            manager.flightDeletionRecords = { deletions }
            manager.localSnapshot = { ([], AppSettings()) }
            return manager
        }
        defaults.set(true, forKey: DataPersistenceManager.syncPreferenceKey)
        let first = launch()
        first.markFlightSynced(doomed.id, modifiedAt: doomed.modifiedAt)
        first.persistSyncedFingerprints()
        let firstEngine = try await started(first)
        XCTAssertEqual(firstEngine.deletes, records(of: doomed.id))

        let second = launch()
        XCTAssertEqual(second.owedFlightDeletions, [doomed.id], "persisted")
        let secondEngine = try await started(second)
        XCTAssertEqual(secondEngine.deletes, records(of: doomed.id), "sent again: not confirmed yet")
        second.clearPendingFlightDeletion(doomed.id)   // CloudKit confirmed it (or answered unknownItem)

        let third = launch()
        let thirdEngine = try await started(third)
        XCTAssertTrue(third.owedFlightDeletions.isEmpty)
        XCTAssertTrue(thirdEngine.deletes.isEmpty, "drained: \(thirdEngine.deletes)")
    }

    /// Owed only for a copy CloudKit still holds as it was deleted: never for a flight it never
    /// held, a later edit it holds (fetched before the decision), a record not downloaded yet, or a
    /// flight the logbook holds alive again (sent instead).
    func testOnlyWhatCloudKitStillHoldsAsItWasDeletedIsOwed() async throws {
        let deletedAt = base.addingTimeInterval(60)
        let held = UUID(), trackOnly = UUID(), neverHeld = UUID(), editedLater = UUID(), undated = UUID()
        let reimported = flight(modified: 120)
        let manager = manager(on: true)
        manager.markFlightSynced(held, modifiedAt: base)
        manager.markFlightTrackSynced(trackOnly, count: 12)
        manager.markFlightSynced(editedLater, modifiedAt: base.addingTimeInterval(61))
        manager.markFlightSynced(undated, modifiedAt: base)
        manager.markFlightSynced(reimported.id, modifiedAt: base)
        let deletions = ledger([(held, deletedAt), (trackOnly, deletedAt), (neverHeld, deletedAt),
                                (editedLater, deletedAt), (undated, nil), (reimported.id, deletedAt)])
        manager.flightDeletionRecords = { deletions }
        manager.localSnapshot = { ([reimported], AppSettings()) }

        let engine = try await started(manager)

        XCTAssertEqual(engine.deletes, records(of: held).union(records(of: trackOnly)))
        XCTAssertEqual(manager.owedFlightDeletions, [held, trackOnly])
        XCTAssertEqual(engine.saves, records(of: reimported.id))
    }

    /// The catch-up sends what CloudKit lacks, never a flight the records say is dead (a copy still
    /// in memory, say).
    func testTheCatchUpNeverSendsADeadFlight() async throws {
        let (dead, alive) = (flight(modified: 0), flight(modified: 0))
        let manager = manager(on: true)
        let deletions = ledger([(dead.id, base.addingTimeInterval(60))])
        manager.flightDeletionRecords = { deletions }
        manager.localSnapshot = { ([dead, alive], AppSettings()) }

        let engine = try await started(manager)

        XCTAssertEqual(engine.saves, records(of: alive.id))
        XCTAssertTrue(engine.deletes.isEmpty, "CloudKit never held it")
    }

    // MARK: Deletes received from CloudKit

    /// Another device deleted through CloudKit, maybe without iCloud Drive: this device records it,
    /// dated on receipt (or the copy's own stamp, when ahead), unless a record of it is here already,
    /// downloaded or not.
    func testADeleteReceivedFromCloudKitLeavesARecordUnlessOneIsHere() async throws {
        defaults.set(true, forKey: DataPersistenceManager.syncPreferenceKey)
        let store = DataPersistenceManager(rootDirectory: local, iCloudDocumentsDirectory: cloud, preferences: defaults)
        let sync = SyncManager(defaults: defaults, backend: backend)
        _ = makeTestAppState(datastore: store, syncManager: sync)
        let (received, ahead, recorded, evicted) = (UUID(), UUID(), UUID(), UUID())
        DeletionRecords.write(.flight, id: recorded, deletedAt: base, storeRoot: cloud)
        let folder = DeletionRecords.folder(in: cloud)
        let placeholder = folder.appendingPathComponent(".\(DeletionRecords.fileName(.flight, id: evicted)).icloud")
        XCTAssertTrue(fm.createFile(atPath: placeholder.path, contents: Data()))
        let aheadStamp = Date().addingTimeInterval(3_600)
        let before = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

        let deleted: [(id: UUID, stamp: Date?)] = [(received, base), (ahead, aheadStamp), (recorded, nil), (evicted, nil)]
        let notify = try XCTUnwrap(sync.onFlightsDeletedInCloudKit, "AppState records them")
        notify(deleted)

        let receipt = try XCTUnwrap(DeletionRecords.mark(.flight, id: received, storeRoot: cloud)?.deletedAt)
        XCTAssertGreaterThanOrEqual(receipt, before)
        XCTAssertLessThanOrEqual(receipt, Date())
        let raised = try XCTUnwrap(DeletionRecords.mark(.flight, id: ahead, storeRoot: cloud)?.deletedAt)
        XCTAssertEqual(raised.timeIntervalSince1970, aheadStamp.timeIntervalSince1970.rounded(.down))
        XCTAssertEqual(DeletionRecords.mark(.flight, id: recorded, storeRoot: cloud)?.deletedAt, base, "the real date stays")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(DeletionRecords.fileName(.flight, id: evicted)).path))
        XCTAssertNil(DeletionRecords.mark(.flight, id: received, storeRoot: local), "the store in use only")
    }
}
