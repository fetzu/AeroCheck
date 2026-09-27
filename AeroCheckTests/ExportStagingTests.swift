import XCTest
@testable import AeroCheck

/// Exported files are staged one directory per export and removed once nothing holds them. They
/// used to be written into tmp/ with a bare `.atomic` and never removed: every share of the
/// logbook, a track or a nav log left a copy of it behind. (S9-06)
///
/// Every test stages under its own temporary root, never the app's `tmp/Exports`.
final class ExportStagingTests: XCTestCase {

    private var root: URL!
    private var legacy: URL!

    override func setUp() {
        super.setUp()
        let base = makeTestDirectory()
        root = base.appendingPathComponent("Exports", isDirectory: true)
        legacy = base.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testEachExportGetsADirectoryOfItsOwn() throws {
        let first = try ExportStaging.stage(Data("one".utf8), filename: "AeroCheck_Logbook.pdf", root: root)
        let second = try ExportStaging.stage(Data("two".utf8), filename: "AeroCheck_Logbook.pdf", root: root)

        XCTAssertNotEqual(first, second, "the same name must not overwrite an export still being shared")
        XCTAssertEqual(first.lastPathComponent, "AeroCheck_Logbook.pdf", "the name the recipient sees is kept")
        XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    func testDiscardRemovesThatExportOnly() throws {
        let first = try ExportStaging.stage(Data("one".utf8), filename: "a.gpx", root: root)
        let second = try ExportStaging.stage(Data("two".utf8), filename: "b.gpx", root: root)

        ExportStaging.discard(first, root: root)

        XCTAssertFalse(exists(first.deletingLastPathComponent()), "the export's directory goes with it")
        XCTAssertTrue(exists(second))
    }

    func testDiscardLeavesAnythingOutsideTheStagingRootAlone() throws {
        let outside = legacy.appendingPathComponent("keep.json")
        try Data("{}".utf8).write(to: outside)

        ExportStaging.discard(outside, root: root)

        XCTAssertTrue(exists(outside))
        XCTAssertTrue(exists(legacy), "not even the directory holding it")
    }

    func testAStagedExportIsRemovedWithTheLastReference() throws {
        var url: URL?
        try autoreleasepool {
            let file = try StagedExport(data: Data("pdf".utf8), filename: "LSGG-LSZB_NavLog.pdf", root: root)
            url = file.url
            XCTAssertTrue(exists(file.url))
        }

        let staged = try XCTUnwrap(url)
        XCTAssertFalse(exists(staged))
        XCTAssertFalse(exists(staged.deletingLastPathComponent()))
    }

    /// The share sheet's item: staged when first asked for, removed with it.
    @MainActor
    func testAShareFileStagesOnFirstUseAndIsRemovedWithIt() throws {
        var url: URL?
        try autoreleasepool {
            let file = ShareFile(data: Data("zip".utf8), filename: "AeroCheck_ExportBundle.zip",
                                 dataTypeIdentifier: "public.zip-archive", root: root)
            XCTAssertFalse(exists(root), "nothing is written until the file is asked for")

            let first = file.url
            XCTAssertTrue(exists(first))
            XCTAssertEqual(file.url, first, "staged once")
            XCTAssertEqual(try Data(contentsOf: first), Data("zip".utf8))
            url = first
        }

        let staged = try XCTUnwrap(url)
        XCTAssertFalse(exists(staged), "closing the share sheet releases the item, which removes the file")
    }

    func testSweepRemovesStagedExportsFromBeforeTheCutoffAndLegacyLooseFiles() throws {
        let old = try ExportStaging.stage(Data("old".utf8), filename: "old.pdf", root: root)
        let cutoff = Date().addingTimeInterval(1)
        let loose = legacy.appendingPathComponent("AeroCheck_20260101_1200_Flight.gpx")
        let unrelated = legacy.appendingPathComponent("notes.txt")
        let nested = legacy.appendingPathComponent("Inbox", isDirectory: true)
        try Data("gpx".utf8).write(to: loose)
        try Data("txt".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: nested.appendingPathComponent("import.pdf"))

        ExportStaging.sweep(before: cutoff, root: root, legacyDirectory: legacy)

        XCTAssertFalse(exists(old))
        XCTAssertFalse(exists(loose), "the loose exports older builds left at the top of tmp/")
        XCTAssertTrue(exists(unrelated), "only export types")
        XCTAssertTrue(exists(nested.appendingPathComponent("import.pdf")), "only the top level")
    }

    func testSweepKeepsAnExportStagedSinceTheCutoff() throws {
        let cutoff = Date().addingTimeInterval(-60)
        let fresh = try ExportStaging.stage(Data("new".utf8), filename: "fresh.pdf", root: root)

        ExportStaging.sweep(before: cutoff, root: root, legacyDirectory: nil)

        XCTAssertTrue(exists(fresh), "a share opened since launch is still being read")
    }

    func testFilenamesStayOnePathComponent() {
        XCTAssertEqual(ExportStaging.safeFilename("LSGG/LSZB_NavLog.pdf"), "LSGG-LSZB_NavLog.pdf")
        XCTAssertEqual(ExportStaging.safeFilename("../x.gpx"), "..-x.gpx")
        XCTAssertEqual(ExportStaging.safeFilename(".."), "Export")
        XCTAssertEqual(ExportStaging.safeFilename("  "), "Export")
    }
}
