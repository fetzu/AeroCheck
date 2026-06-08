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
