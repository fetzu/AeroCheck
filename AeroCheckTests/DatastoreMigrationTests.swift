import XCTest
@testable import AeroCheck

/// Tests the one-time relocation of the local datastore out of the file-sharing-exposed Documents
/// root into Application Support. The migration must be safe (never overwrite, never lose data) and
/// idempotent. (SEC-12)
final class DatastoreMigrationTests: XCTestCase {

    private let fm = FileManager.default
    private var tempRoot: URL!
    private var oldBase: URL!
    private var newBase: URL!

    override func setUpWithError() throws {
        tempRoot = fm.temporaryDirectory.appendingPathComponent("ac-migration-\(UUID().uuidString)")
        oldBase = tempRoot.appendingPathComponent("Documents")
        newBase = tempRoot.appendingPathComponent("AppSupport")
        try fm.createDirectory(at: oldBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempRoot)
    }

    func testMovesSensitiveItemsButLeavesMapTiles() throws {
        // Old layout: Flights/ (with a logbook entry), settings.json, and MapData/ (public cache).
        let flights = oldBase.appendingPathComponent("Flights")
        try fm.createDirectory(at: flights, withIntermediateDirectories: true)
        try Data("flight".utf8).write(to: flights.appendingPathComponent("a.json"))
        try Data("settings".utf8).write(to: oldBase.appendingPathComponent("settings.json"))
        let mapData = oldBase.appendingPathComponent("MapData")
        try fm.createDirectory(at: mapData, withIntermediateDirectories: true)

        let moved = DataPersistenceManager.migrateLocalDatastore(from: oldBase, to: newBase, fileManager: fm)

        XCTAssertEqual(moved, 2, "Flights and settings.json move; MapData does not")
        XCTAssertTrue(fm.fileExists(atPath: newBase.appendingPathComponent("Flights/a.json").path))
        XCTAssertTrue(fm.fileExists(atPath: newBase.appendingPathComponent("settings.json").path))
        // Sensitive sources are moved away from the exposed Documents folder…
        XCTAssertFalse(fm.fileExists(atPath: flights.path))
        XCTAssertFalse(fm.fileExists(atPath: oldBase.appendingPathComponent("settings.json").path))
        // …but the non-sensitive map tile cache stays in Documents.
        XCTAssertTrue(fm.fileExists(atPath: mapData.path))
        XCTAssertFalse(fm.fileExists(atPath: newBase.appendingPathComponent("MapData").path))
    }

    func testNeverOverwritesAnExistingDestination() throws {
        try Data("old".utf8).write(to: oldBase.appendingPathComponent("settings.json"))
        try fm.createDirectory(at: newBase, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBase.appendingPathComponent("settings.json"))

        let moved = DataPersistenceManager.migrateLocalDatastore(from: oldBase, to: newBase, fileManager: fm)

        XCTAssertEqual(moved, 0, "An already-migrated destination must not be overwritten")
        // The destination keeps its content and the source is left intact (no data loss).
        XCTAssertEqual(
            try String(contentsOf: newBase.appendingPathComponent("settings.json"), encoding: .utf8),
            "new"
        )
        XCTAssertTrue(fm.fileExists(atPath: oldBase.appendingPathComponent("settings.json").path))
    }

    func testIsIdempotent() throws {
        try Data("flight".utf8).write(to: oldBase.appendingPathComponent("active_flight.json"))

        let first = DataPersistenceManager.migrateLocalDatastore(from: oldBase, to: newBase, fileManager: fm)
        let second = DataPersistenceManager.migrateLocalDatastore(from: oldBase, to: newBase, fileManager: fm)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "A second run has nothing to move")
        XCTAssertTrue(fm.fileExists(atPath: newBase.appendingPathComponent("active_flight.json").path))
    }

    func testNothingToMigrateReturnsZero() {
        let moved = DataPersistenceManager.migrateLocalDatastore(from: oldBase, to: newBase, fileManager: fm)
        XCTAssertEqual(moved, 0)
    }
}

/// "Sync to iCloud" covers the iCloud Drive store as well as CloudKit. The switch only ever gated
/// CloudKit: flights, plans, threads, trips and settings kept going to the app's iCloud Drive folder
/// whenever iCloud was available. Off now means the datastore is local, with nothing deleted on
/// either side and nothing the pilot saw disappearing. (author decision 2026-09-28)
///
/// A plain directory stands in for the iCloud Drive container.
@MainActor
final class SyncSwitchDatastoreTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var local: URL!
    private var cloud: URL!
    private var preferences: UserDefaults!

    override func setUpWithError() throws {
        let base = makeTestDirectory()
        local = base.appendingPathComponent("AppSupport", isDirectory: true)
        cloud = base.appendingPathComponent("Container/Documents", isDirectory: true)
        root = local
        preferences = makeTestDefaults()
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    private func datastore() -> DataPersistenceManager {
        DataPersistenceManager(rootDirectory: local, iCloudDocumentsDirectory: cloud, preferences: preferences)
    }

    @discardableResult
    private func write(_ text: String, _ path: String, in base: URL, modified: Date? = nil) throws -> URL {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func read(_ path: String, in base: URL) -> String? {
        (try? Data(contentsOf: base.appendingPathComponent(path))).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func files(in folder: String, of base: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(folder).path)) ?? [])
    }

    // MARK: - The store follows the switch

    func testOnAFreshInstallTheDatastoreIsInICloudDrive() {
        let store = datastore()

        XCTAssertTrue(store.usesICloudDrive, "the switch is on by default")
        XCTAssertTrue(store.isUsingICloudDrive)
        XCTAssertTrue(store.flightsDirectory.path.hasPrefix(cloud.path))
        XCTAssertTrue(store.tripsFileURL.path.hasPrefix(cloud.path))
    }

    func testSwitchingOffCopiesICloudDriveHomeAndDeletesNothing() throws {
        try write("flight A", "Flights/a.json", in: cloud)
        try write("plan P", "NavigationPlans/p.json", in: cloud)
        try write("thread T", "FlightThreads/t.json", in: cloud)
        try write("settings", "settings.json", in: cloud)
        try write("trips", "trips.json", in: cloud)
        let store = datastore()
        let moved = expectation(forNotification: .datastoreLocationDidChange, object: store)

        XCTAssertTrue(store.setUsesICloudDrive(false))

        wait(for: [moved], timeout: 1)
        XCTAssertFalse(store.isUsingICloudDrive)
        XCTAssertTrue(store.flightsDirectory.path.hasPrefix(local.path))
        for path in ["Flights/a.json", "NavigationPlans/p.json", "FlightThreads/t.json", "settings.json", "trips.json"] {
            XCTAssertNotNil(read(path, in: local), "\(path) must be there locally once the switch is off")
            XCTAssertNotNil(read(path, in: cloud), "\(path) must stay in iCloud Drive")
        }
        XCTAssertEqual(preferences.object(forKey: DataPersistenceManager.syncPreferenceKey) as? Bool, false)
    }

    func testWhileOffNothingIsWrittenToICloudDrive() throws {
        let store = datastore()
        store.setUsesICloudDrive(false)
        let before = files(in: "Flights", of: cloud)

        store.saveSettings(AppSettings())
        XCTAssertTrue(store.saveFlight(Flight(airplane: "wt9-dynamic", startTime: Date())))

        XCTAssertEqual(files(in: "Flights", of: cloud), before)
        XCTAssertNil(read("settings.json", in: cloud))
        XCTAssertNotNil(read("settings.json", in: local))
        XCTAssertEqual(files(in: "Flights", of: local).count, 1)
    }

    func testSwitchingBackOnBringsWhatWasDoneOffline() throws {
        let long = Date(timeIntervalSinceNow: -86_400)
        let recent = Date()
        let store = datastore()
        store.setUsesICloudDrive(false)
        try write("recorded while off", "Flights/new.json", in: local)
        try write("edited while off", "Flights/edited.json", in: local, modified: recent)
        try write("the old copy", "Flights/edited.json", in: cloud, modified: long)
        try write("stale local copy", "Flights/other-device.json", in: local, modified: long)
        try write("edited on another device", "Flights/other-device.json", in: cloud, modified: recent)

        XCTAssertTrue(store.setUsesICloudDrive(true))

        XCTAssertTrue(store.isUsingICloudDrive)
        XCTAssertEqual(read("Flights/new.json", in: cloud), "recorded while off")
        XCTAssertEqual(read("Flights/edited.json", in: cloud), "edited while off", "newer local copy wins")
        XCTAssertEqual(read("Flights/other-device.json", in: cloud), "edited on another device",
                       "an older local copy never replaces a newer one")
        XCTAssertNotNil(read("Flights/new.json", in: local), "nothing is deleted locally either")
    }

    func testThePlansIndexIsLeftToTheStoreItBelongsTo() throws {
        try write("[]", "NavigationPlans/plans_index.json", in: cloud)
        let store = datastore()

        store.setUsesICloudDrive(false)

        XCTAssertNil(read("NavigationPlans/plans_index.json", in: local))
    }

    func testTheSameSwitchTwiceMovesNothing() {
        let store = datastore()
        XCTAssertFalse(store.setUsesICloudDrive(true))
        store.setUsesICloudDrive(false)
        XCTAssertFalse(store.setUsesICloudDrive(false))
    }

    // MARK: - Devices upgrading with the switch already off

    /// Up to this build a device with the switch off still kept everything in iCloud Drive; this
    /// build reads it locally. The first launch copies it home, or the logbook would come up empty.
    func testAnUpgradedDeviceWithTheSwitchOffFindsItsDataLocally() throws {
        preferences.set(false, forKey: DataPersistenceManager.syncPreferenceKey)
        try write("flight A", "Flights/a.json", in: cloud)
        try write("settings", "settings.json", in: cloud)

        let store = datastore()

        XCTAssertFalse(store.isUsingICloudDrive)
        XCTAssertEqual(read("Flights/a.json", in: local), "flight A")
        XCTAssertEqual(read("settings.json", in: local), "settings")
        XCTAssertEqual(read("Flights/a.json", in: cloud), "flight A", "iCloud Drive is left as it was")
    }

    /// Once copied, iCloud Drive is not read again while the switch stays off.
    func testWhileOffLaterICloudChangesAreNotReadIn() throws {
        preferences.set(false, forKey: DataPersistenceManager.syncPreferenceKey)
        _ = datastore()
        try write("from another device", "Flights/b.json", in: cloud)

        _ = datastore() // relaunch

        XCTAssertNil(read("Flights/b.json", in: local))
    }

    func testAnUpgradedDeviceWithTheSwitchOnIsLeftAsItWas() throws {
        preferences.set(true, forKey: DataPersistenceManager.syncPreferenceKey)
        try write("flight A", "Flights/a.json", in: cloud)

        let store = datastore()

        XCTAssertTrue(store.isUsingICloudDrive)
        XCTAssertNil(read("Flights/a.json", in: local), "nothing to copy while the store stays in iCloud Drive")
    }

    /// A file iCloud has not downloaded cannot be copied without waiting on the network: the copy
    /// stays owed and the next launch finishes it.
    func testAFileNotDownloadedYetIsCopiedOnALaterLaunch() throws {
        try write("", "Flights/.late.json.icloud", in: cloud)
        try write("flight A", "Flights/a.json", in: cloud)
        let store = datastore()

        store.setUsesICloudDrive(false)

        XCTAssertEqual(read("Flights/a.json", in: local), "flight A")
        XCTAssertNil(read("Flights/late.json", in: local))
        XCTAssertNotNil(preferences.string(forKey: DataPersistenceManager.pendingMergeKey), "still owed")

        // iCloud has downloaded it since.
        try fm.removeItem(at: cloud.appendingPathComponent("Flights/.late.json.icloud"))
        try write("flight L", "Flights/late.json", in: cloud)
        _ = datastore() // relaunch

        XCTAssertEqual(read("Flights/late.json", in: local), "flight L")
        XCTAssertNil(preferences.string(forKey: DataPersistenceManager.pendingMergeKey))
    }

    // MARK: - AppState

    /// The switch is the device's: a settings file saying otherwise (another device's, or an old
    /// one) does not move this device's data.
    func testTheDeviceSwitchWinsOverTheSettingsFile() throws {
        preferences.set(false, forKey: DataPersistenceManager.syncPreferenceKey)
        let store = datastore()
        var file = AppSettings()
        file.iCloudSyncEnabled = true
        store.saveSettings(file)

        let appState = makeTestAppState(datastore: store)

        XCTAssertFalse(appState.settings.iCloudSyncEnabled)
        XCTAssertFalse(store.isUsingICloudDrive)
    }

    /// No stored choice yet: the value in the loaded settings is adopted, and off moves the store.
    func testWithoutAStoredChoiceTheLoadedSettingsDecide() throws {
        var file = AppSettings()
        file.iCloudSyncEnabled = false
        datastore().saveSettings(file) // lands in iCloud Drive: the switch is on by default
        preferences.removeObject(forKey: DataPersistenceManager.syncPreferenceKey)
        let store = datastore()

        let appState = makeTestAppState(datastore: store)

        XCTAssertFalse(appState.settings.iCloudSyncEnabled)
        XCTAssertFalse(store.isUsingICloudDrive)
        XCTAssertNotNil(read("settings.json", in: local), "the settings came home with the rest")
        XCTAssertEqual(preferences.object(forKey: DataPersistenceManager.syncPreferenceKey) as? Bool, false)
    }

    func testTurningTheSwitchOffInSettingsMovesTheStore() throws {
        let store = datastore()
        let appState = makeTestAppState(datastore: store)
        XCTAssertTrue(store.isUsingICloudDrive)

        appState.settings.iCloudSyncEnabled = false
        appState.saveSettings()

        XCTAssertFalse(store.isUsingICloudDrive)
        let saved = try XCTUnwrap(store.loadSettings(), "saved in the local store")
        XCTAssertFalse(saved.iCloudSyncEnabled)
    }

    // MARK: - Trips: merged trip by trip

    /// `trips.json` holds every trip. Copied whole (the newer file wins), it replaced the other
    /// store's trips with this one's, and a trip only the other store held was gone from it while
    /// its legs, one file each, kept pointing at it.

    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    /// Whole seconds: the file stores ISO 8601 dates.
    private func trip(_ name: String, id: UUID = UUID(), updated: TimeInterval) -> Trip {
        var trip = Trip(id: id, legIds: [UUID(), UUID()])
        trip.name = name
        trip.createdAt = base
        trip.updatedAt = base.addingTimeInterval(updated)
        return trip
    }

    private func writeTrips(_ trips: [Trip], in store: URL, modified: Date? = nil) throws {
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let url = store.appendingPathComponent("trips.json")
        try DataPersistenceManager.encodeTrips(trips).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    /// Trip names by id, as the store's file holds them. Nil when there is no readable file.
    private func tripNames(in store: URL) -> [UUID: String]? {
        guard let data = try? Data(contentsOf: store.appendingPathComponent("trips.json")),
              let trips = DataPersistenceManager.decodeTrips(data) else { return nil }
        return Dictionary(trips.map { ($0.id, $0.name ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testSwitchingOffMergesTheTripsTripByTrip() throws {
        let store = datastore()
        let (shared, editedHere, onlyInICloud, onlyHere) = (UUID(), UUID(), UUID(), UUID())
        let cloudTrips = [trip("edited on the other device", id: shared, updated: 200),
                          trip("older in iCloud", id: editedHere, updated: 100),
                          trip("formed on the other device", id: onlyInICloud, updated: 50)]
        try writeTrips(cloudTrips, in: cloud, modified: Date())
        try writeTrips([trip("stale here", id: shared, updated: 100),
                        trip("edited here", id: editedHere, updated: 300),
                        trip("only here", id: onlyHere, updated: 50)],
                       in: local, modified: Date(timeIntervalSinceNow: -86_400))

        XCTAssertTrue(store.setUsesICloudDrive(false))

        XCTAssertEqual(tripNames(in: local), [shared: "edited on the other device",
                                              editedHere: "edited here",
                                              onlyInICloud: "formed on the other device",
                                              onlyHere: "only here"])
        XCTAssertEqual(tripNames(in: cloud), Dictionary(uniqueKeysWithValues: cloudTrips.map { ($0.id, $0.name!) }),
                       "the store being left is not touched")
    }

    func testSwitchingOnMergesTheTripsTripByTrip() throws {
        let store = datastore()
        store.setUsesICloudDrive(false)
        let (shared, editedThere, onlyThere, onlyHere) = (UUID(), UUID(), UUID(), UUID())
        try writeTrips([trip("edited here while off", id: shared, updated: 300),
                        trip("older here", id: editedThere, updated: 100),
                        trip("formed here while off", id: onlyHere, updated: 50)], in: local)
        try writeTrips([trip("stale in iCloud", id: shared, updated: 100),
                        trip("edited on the other device", id: editedThere, updated: 200),
                        trip("formed on the other device", id: onlyThere, updated: 50)], in: cloud)

        XCTAssertTrue(store.setUsesICloudDrive(true))

        XCTAssertEqual(tripNames(in: cloud), [shared: "edited here while off",
                                              editedThere: "edited on the other device",
                                              onlyThere: "formed on the other device",
                                              onlyHere: "formed here while off"])
        XCTAssertEqual(tripNames(in: local)?.count, 3, "the local store keeps its own copy")
    }

    /// The #203 gap itself: the store being left held the NEWER file, which replaced the other one.
    func testANewerTripsFileNoLongerDropsATripTheOtherStoreHolds() throws {
        let store = datastore()
        store.setUsesICloudDrive(false)
        let (mine, theirs) = (UUID(), UUID())
        try writeTrips([trip("formed here while off", id: mine, updated: 10)], in: local, modified: Date())
        try writeTrips([trip("formed on the other device", id: theirs, updated: 10)], in: cloud,
                       modified: Date(timeIntervalSinceNow: -3_600))

        store.setUsesICloudDrive(true)

        XCTAssertEqual(tripNames(in: cloud), [mine: "formed here while off", theirs: "formed on the other device"])
    }

    /// Nothing to merge with: the file is copied as it is, as #203 did.
    func testATripsFileOnOneSideOnlyIsCopiedAsItIs() throws {
        let only = trip("formed on the other device", updated: 10)
        try writeTrips([only], in: cloud)

        datastore().setUsesICloudDrive(false)

        XCTAssertEqual(read("trips.json", in: local), read("trips.json", in: cloud))
    }

    /// A trips file written by a build before trips had a name or a date merges like any other.
    func testATripsFileFromAnOlderBuildMerges() throws {
        let store = datastore()
        let old = UUID()
        try write("""
            [{"id":"\(old.uuidString)","legIds":["\(UUID().uuidString)","\(UUID().uuidString)"],
              "sharedTasks":[],"createdAt":"2026-06-01T10:00:00Z","updatedAt":"2026-06-01T10:00:00Z"}]
            """, "trips.json", in: cloud)
        let recent = trip("formed here", updated: 10)
        try writeTrips([recent], in: local)

        store.setUsesICloudDrive(false)

        let names = try XCTUnwrap(tripNames(in: local))
        XCTAssertEqual(Set(names.keys), [old, recent.id])
    }

    /// An unreadable trips file (damaged, or from a build this one cannot read) never replaces a
    /// readable one, however new it is.
    func testAnUnreadableTripsFileNeverReplacesAReadableOne() throws {
        let store = datastore()
        let kept = trip("formed here", updated: 10)
        try writeTrips([kept], in: local, modified: Date(timeIntervalSinceNow: -86_400))
        try write("not a trips file", "trips.json", in: cloud, modified: Date())

        store.setUsesICloudDrive(false)

        XCTAssertEqual(tripNames(in: local), [kept.id: "formed here"])
    }

    /// A trips file iCloud has evicted cannot be merged into without its content: the merge stays
    /// owed, and nothing is written next to the placeholder.
    func testAnEvictedTripsFileKeepsTheMergeOwed() throws {
        let store = datastore()
        store.setUsesICloudDrive(false)
        try writeTrips([trip("formed here while off", updated: 10)], in: local)
        try write("", ".trips.json.icloud", in: cloud)

        store.setUsesICloudDrive(true)

        XCTAssertNil(read("trips.json", in: cloud), "never written over an evicted file")
        XCTAssertNotNil(preferences.string(forKey: DataPersistenceManager.pendingMergeKey), "still owed")
    }

    func testMergingTheTripsTwiceWritesNothingTheSecondTime() throws {
        try writeTrips([trip("one", updated: 10)], in: local)
        try writeTrips([trip("two", updated: 10)], in: cloud)

        let first = DataPersistenceManager.mergeDatastore(from: local, into: cloud, fileManager: fm)
        let second = DataPersistenceManager.mergeDatastore(from: local, into: cloud, fileManager: fm)

        XCTAssertEqual(first.copied, 1)
        XCTAssertEqual(second.copied, 0)
        XCTAssertEqual(tripNames(in: cloud)?.count, 2)
    }

    func testTheNewerCopyOfATripWinsAndATieKeepsTheBase() {
        let id = UUID()
        let older = trip("older", id: id, updated: 10)
        let newer = trip("newer", id: id, updated: 20)
        let tie = trip("tie", id: id, updated: 10)

        XCTAssertEqual(Trip.merged([older], with: [newer]).map(\.name), ["newer"])
        XCTAssertEqual(Trip.merged([newer], with: [older]).map(\.name), ["newer"])
        XCTAssertEqual(Trip.merged([older], with: [tie]).map(\.name), ["older"])
    }

    // MARK: - Trips: the manager after a move

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// After the move, memory holds the old store's copy of a trip and the new store may hold a newer
    /// one. Memory used to win, and the next save wrote the stale copy back over the newer one.
    func testAfterTheSwitchTheManagerHoldsBothStoresTripsAndTheNewerCopy() async throws {
        let (shared, onlyInICloud, onlyHere) = (UUID(), UUID(), UUID())
        try writeTrips([trip("stale in iCloud", id: shared, updated: 100),
                        trip("formed on the other device", id: onlyInICloud, updated: 50)], in: cloud)
        let store = datastore()
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        XCTAssertEqual(manager.trips.count, 2)
        try writeTrips([trip("edited here", id: shared, updated: 300),
                        trip("formed here", id: onlyHere, updated: 50)], in: local)

        store.setUsesICloudDrive(false)

        try await waitUntil { manager.trips.count == 3 && manager.trip(withId: shared)?.name == "edited here" }
        XCTAssertEqual(Set(manager.trips.map(\.id)), [shared, onlyInICloud, onlyHere])
        XCTAssertEqual(manager.trip(withId: shared)?.name, "edited here", "the newer copy, not memory's")
    }

    // MARK: - Trips: the local file from before the switch

    /// A local trips.json from before the switch (the pre-5.0.1 one, or one written while iCloud
    /// was unreachable) was superseded by the iCloud copy. Left in place, the first switch-off would
    /// merge its trips into the local store, dissolved ones included. It is set aside, not deleted.
    func testAPreSwitchLocalTripsFileIsSetAsideWhenICloudHoldsTheTrips() throws {
        let dissolvedSince = trip("dissolved since 5.0.0", updated: 10)
        let current = trip("the trip today", updated: 20)
        try writeTrips([dissolvedSince], in: local)
        try writeTrips([current], in: cloud)

        let store = datastore()

        XCTAssertNil(read("trips.json", in: local))
        XCTAssertNotNil(read(DataPersistenceManager.preSwitchTripsFileName, in: local), "kept, under another name")
        store.setUsesICloudDrive(false)
        XCTAssertEqual(tripNames(in: local), [current.id: "the trip today"], "nothing comes back from before")
    }

    /// With no trips.json in iCloud Drive, the local one is the only copy (the pre-5.0.1 upgrade):
    /// it stays, and the load reads it.
    func testAPreSwitchLocalTripsFileStaysWhenICloudHasNone() async throws {
        let only = trip("formed on 5.0.0", updated: 10)
        try writeTrips([only], in: local)

        let store = datastore()

        XCTAssertNotNil(read("trips.json", in: local))
        let loaded = await store.loadTripsOffMain()
        XCTAssertEqual(loaded.map(\.id), [only.id])
    }

    /// An evicted iCloud trips.json has trips; the local store's file must not stand in for them
    /// (the next save would have written it over them).
    func testTheLocalTripsFileNeverStandsInForAnEvictedOne() async throws {
        let store = datastore()
        try writeTrips([trip("the local store's", updated: 10)], in: local)
        try write("", ".trips.json.icloud", in: cloud)

        let loaded = await store.loadTripsOffMain()

        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Flight pages: the newer copy after a move

    private func page(_ name: String, id: UUID = UUID(), updated: TimeInterval,
                      state: FlightThreadState = .planned) -> FlightThread {
        var page = FlightThread(routeLabel: "LSZQ → LSGY")
        page.id = id
        page.name = name
        page.state = state
        page.createdAt = base
        page.updatedAt = base.addingTimeInterval(updated)
        return page
    }

    /// Writes pages into a store's FlightThreads folder, their files stamped `modified`.
    private func writePages(_ pages: [FlightThread], in store: URL, modified: Date) throws {
        let folder = store.appendingPathComponent("FlightThreads", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        DataPersistenceManager.writeFlightThreadFiles(pages, to: folder)
        for page in pages {
            let url = folder.appendingPathComponent(DataPersistenceManager.flightThreadFilename(for: page))
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func pages(in store: URL) -> [UUID: FlightThread] {
        let pages = DataPersistenceManager.decodeFlightThreads(in: store.appendingPathComponent("FlightThreads"))
        return Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func testTheNewerPageWinsATieKeepsMemorysAndNothingIsDropped() {
        let (shared, tied, onlyInMemory, onlyLoaded) = (UUID(), UUID(), UUID(), UUID())
        let memory = [page("stale", id: shared, updated: 100), page("memory's", id: tied, updated: 50),
                      page("only in memory", id: onlyInMemory, updated: 10)]
        let loaded = [page("edited on the other device", id: shared, updated: 300),
                      page("the store's", id: tied, updated: 50), page("only on disk", id: onlyLoaded, updated: 10)]

        let merged = FlightThreadManager.mergedThreads(memory: memory, loaded: loaded)

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0.name ?? "") }),
                       [shared: "edited on the other device", tied: "memory's",
                        onlyInMemory: "only in memory", onlyLoaded: "only on disk"])
        XCTAssertEqual(FlightThreadManager.mergedThreads(memory: loaded, loaded: memory).first { $0.id == shared }?.name,
                       "edited on the other device", "the newer copy, whichever side it is on")
    }

    /// Switching off: memory holds iCloud's copy of a page, the local store a newer one (edited
    /// there during an earlier off period). Memory used to win.
    func testAfterSwitchingOffTheManagerShowsTheNewerCopyOfAPage() async throws {
        let store = datastore()
        let (shared, onlyInICloud, onlyHere) = (UUID(), UUID(), UUID())
        let long = Date(timeIntervalSinceNow: -86_400)
        try writePages([page("stale in iCloud", id: shared, updated: 100),
                        page("planned on the other device", id: onlyInICloud, updated: 50)], in: cloud, modified: long)
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        XCTAssertEqual(manager.threads.count, 2)
        try writePages([page("edited here while off", id: shared, updated: 300),
                        page("planned here while off", id: onlyHere, updated: 50)], in: local, modified: Date())

        store.setUsesICloudDrive(false)

        try await waitUntil { manager.threads.count == 3 && manager.thread(withId: shared)?.name == "edited here while off" }
        XCTAssertEqual(manager.thread(withId: shared)?.name, "edited here while off")
        XCTAssertEqual(Set(manager.threads.map(\.id)), [shared, onlyInICloud, onlyHere], "a page on one side only stays")
    }

    /// Switching on: memory holds the local copy, iCloud Drive a newer one from another device.
    func testAfterSwitchingOnTheManagerShowsTheNewerCopyOfAPage() async throws {
        let store = datastore()
        store.setUsesICloudDrive(false)
        let (shared, onlyHere, onlyInICloud) = (UUID(), UUID(), UUID())
        let long = Date(timeIntervalSinceNow: -86_400)
        try writePages([page("stale here", id: shared, updated: 100),
                        page("planned here while off", id: onlyHere, updated: 50)], in: local, modified: long)
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        XCTAssertEqual(manager.threads.count, 2)
        try writePages([page("edited on the other device", id: shared, updated: 300),
                        page("planned on the other device", id: onlyInICloud, updated: 50)], in: cloud, modified: Date())

        store.setUsesICloudDrive(true)

        try await waitUntil { manager.threads.count == 3 && manager.thread(withId: shared)?.name == "edited on the other device" }
        XCTAssertEqual(manager.thread(withId: shared)?.name, "edited on the other device")
        XCTAssertEqual(Set(manager.threads.map(\.id)), [shared, onlyHere, onlyInICloud])
        XCTAssertEqual(pages(in: local)[onlyHere]?.name, "planned here while off", "nothing leaves the local store")
    }

    /// The newer copy is memory's, the new store's file an older one: it stays on screen, and the
    /// next save writes it into the store it now belongs to.
    func testANewerCopyInMemoryReachesTheNewStoreWithTheNextSave() async throws {
        let store = datastore()
        let (shared, other, marker) = (UUID(), UUID(), UUID())
        try writePages([page("edited on the other device", id: shared, updated: 300),
                        page("another flight", id: other, updated: 10)], in: cloud, modified: Date(timeIntervalSinceNow: -86_400))
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        try writePages([page("stale here", id: shared, updated: 100),
                        page("only here", id: marker, updated: 10)], in: local, modified: Date())

        store.setUsesICloudDrive(false)
        try await waitUntil { manager.thread(withId: marker) != nil } // the reload has landed
        XCTAssertEqual(manager.thread(withId: shared)?.name, "edited on the other device")
        manager.renameFlight(other, to: "renamed")

        try await waitUntil { self.pages(in: local)[shared]?.name == "edited on the other device" }
        XCTAssertEqual(pages(in: local)[shared]?.name, "edited on the other device")
    }

    /// A page being flown keeps its copy: one from the other store never saw the flight start, and
    /// would take the flight id (and the close-out at END FLIGHT) off it.
    func testAPageBeingFlownKeepsItsCopy() async throws {
        let store = datastore()
        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }
        let flying = manager.createThread(from: nil, routeLabel: "LSZQ → LSGY")
        defer { manager.deleteThread(threadId: flying.id) }
        let flightId = UUID()
        manager.attachFlight(flightId, toThreadId: flying.id)
        try await waitUntil { self.pages(in: self.cloud)[flying.id]?.state == .flying }
        var elsewhere = flying
        elsewhere.name = "planned on the other device"
        elsewhere.updatedAt = Date().addingTimeInterval(3_600)
        let marker = page("only here", updated: 10)
        try writePages([elsewhere, marker], in: local, modified: Date().addingTimeInterval(3_600))

        store.setUsesICloudDrive(false)
        try await waitUntil { manager.thread(withId: marker.id) != nil } // the reload has landed

        XCTAssertEqual(manager.thread(withId: flying.id)?.state, .flying)
        XCTAssertEqual(manager.thread(withId: flying.id)?.flightId, flightId)
        XCTAssertNil(manager.thread(withId: flying.id)?.name)
    }

    // MARK: - Trips: legs pointing at a trip that is missing

    private func leg(_ label: String, trip tripId: UUID?, created: TimeInterval,
                     countries: [String]? = nil) -> FlightThread {
        var thread = FlightThread(routeLabel: label)
        thread.tripId = tripId
        thread.createdAt = base.addingTimeInterval(created)
        thread.countries = countries
        thread.homeCountry = countries?.first
        return thread
    }

    /// A leg whose trip is missing was in neither list (the flights list shows a leg under its trip
    /// only) and its trip-scoped preparation lived on the trip: the flight vanished. Its trip is
    /// rebuilt from the legs that point at it.
    func testALegWhoseTripIsMissingBringsItsTripBack() async throws {
        let missing = UUID()
        let second = leg("LFSB → LSGY", trip: missing, created: 20)
        let first = leg("LSZQ → LFSB", trip: missing, created: 10)
        let alone = leg("LSZQ → LSZQ", trip: nil, created: 5)
        let other = trip("a trip that is there", updated: 10)
        let store = datastore()
        DataPersistenceManager.writeFlightThreadFiles([second, first, alone], to: store.flightThreadsDirectory)
        try writeTrips([other], in: cloud)
        let onDisk = read("trips.json", in: cloud)

        let manager = makeTestThreadManager(datastore: store)
        try await waitUntil { manager.hasLoadedThreads }

        let rebuilt = try XCTUnwrap(manager.trip(withId: missing), "the legs' trip is back")
        XCTAssertEqual(rebuilt.legIds, [first.id, second.id], "in the order the legs were created")
        XCTAssertEqual(rebuilt.updatedAt, Trip.rebuiltStamp)
        XCTAssertEqual(manager.trip(forThreadId: second.id)?.id, missing)
        let entries = UpcomingOrder.entries(threads: manager.threads, trips: manager.trips)
        let listed = entries.flatMap { entry -> [UUID] in
            switch entry {
            case .trip(let trip): return trip.legIds
            case .flight(let thread): return [thread.id]
            }
        }
        XCTAssertEqual(Set(listed), [first.id, second.id, alone.id], "every flight is on the list")
        XCTAssertEqual(read("trips.json", in: cloud), onDisk, "a load writes nothing")
    }

    /// The rebuild is what a surviving copy can replace: the real trip wins wherever it turns up.
    func testARebuiltTripGivesWayToTheRealOne() {
        let id = UUID()
        let legs = [leg("LSZQ → LFSB", trip: id, created: 10), leg("LFSB → LSGY", trip: id, created: 20)]
        let rebuilt = FlightThreadManager.rebuiltTrips(threads: legs, trips: [])
        var real = trip("the pilot's name", id: id, updated: 0)
        real.legIds = legs.map(\.id).reversed()

        XCTAssertEqual(Trip.merged(rebuilt, with: [real]), [real])
        XCTAssertEqual(Trip.merged([real], with: rebuilt), [real])
    }

    /// The shared preparation went with the trip: it comes back unticked, for each thing any leg
    /// needs. DABS and GAFOR because a leg touches Switzerland.
    func testARebuiltTripAsksForTheSharedPreparationAgain() throws {
        let id = UUID()
        let legs = [leg("LFSB → LFGA", trip: id, created: 10, countries: ["FR"]),
                    leg("LFGA → LSGY", trip: id, created: 20, countries: ["FR", "CH"])]

        let rebuilt = try XCTUnwrap(FlightThreadManager.rebuiltTrips(threads: legs, trips: []).first)

        let keys = Set(rebuilt.sharedTasks.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: [.aircraftReserved, .weatherBriefed, .notamChecked, .dabsChecked, .gaforChecked]),
                      "\(keys)")
        XCTAssertTrue(rebuilt.sharedTasks.allSatisfy { $0.key.scope == .trip })
        XCTAssertTrue(rebuilt.sharedTasks.allSatisfy { $0.state == .pending }, "nothing claims a briefing was done")
    }

    /// A leg another trip lists stays with that trip, and a trip that exists is left alone.
    func testOnlyLegsNoTripListsAreRebuiltIntoOne() {
        let (missing, present) = (UUID(), UUID())
        let listedElsewhere = leg("LSZQ → LFSB", trip: missing, created: 10)
        var existing = trip("there", id: present, updated: 10)
        existing.legIds = [listedElsewhere.id]
        let inTheExisting = leg("LFSB → LSGY", trip: present, created: 20)

        XCTAssertEqual(FlightThreadManager.rebuiltTrips(threads: [listedElsewhere, inTheExisting], trips: [existing]), [])
    }

    /// A lone leg (its partner's file not downloaded yet, say) gets its trip back too, rather than
    /// being cut loose: when the other leg arrives, it joins the same trip.
    func testALoneLegStillGetsItsTripBack() throws {
        let id = UUID()
        let only = leg("LSZQ → LFSB", trip: id, created: 10)

        let rebuilt = try XCTUnwrap(FlightThreadManager.rebuiltTrips(threads: [only], trips: []).first)

        XCTAssertEqual(rebuilt.id, id)
        XCTAssertEqual(rebuilt.legIds, [only.id])
    }
}
