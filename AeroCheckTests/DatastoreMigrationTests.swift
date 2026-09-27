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
}
