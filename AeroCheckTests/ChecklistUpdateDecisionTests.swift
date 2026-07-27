import XCTest
@testable import AeroCheck

/// Covers the rule that decides whether a cached checklist is re-downloaded.
///
/// This had no test, and it failed in the field: in the 2026-07 cycle ten aircraft were corrected,
/// merged and deployed, and every install kept serving the old figures — including a stall speed
/// that read LOW, so an aircraft in that band was stalled and shown green. The app reported itself
/// up to date throughout.
final class ChecklistUpdateDecisionTests: XCTestCase {

    private func decide(
        server: String? = nil, cached: String? = nil,
        serverVersion: String = "01/25", currentVersion: String = "01/25"
    ) -> Bool {
        ChecklistUpdateDecision.needsUpdate(
            serverChecksum: server, cachedChecksum: cached,
            serverVersion: serverVersion, currentVersion: currentVersion
        )
    }

    // MARK: - The regression that shipped

    /// THE BUG. Content changed, so the checksum differs — but the version string did not, because
    /// it mirrors the club document revision and we had only corrected our transcription of it.
    /// The old rule required a cached checksum to be present, fell through to comparing versions,
    /// and answered "up to date".
    func testContentChangedButVersionDidNot_withNoCachedChecksum_stillUpdates() {
        XCTAssertTrue(decide(
            server: "sha-new", cached: nil,
            serverVersion: "01/25", currentVersion: "01/25"
        ), "A missing cached checksum means UNKNOWN, not up-to-date — this is the case that " +
           "silently withheld corrected stall speeds from every affected install.")
    }

    /// Same shape, with the version bump that AeroCheck-checklists now enforces in CI. Belt and
    /// braces: either signal alone must be sufficient.
    func testVersionBumpAloneTriggersUpdate_evenWithoutAnyChecksum() {
        XCTAssertTrue(decide(server: nil, cached: nil,
                             serverVersion: "01/25-2", currentVersion: "01/25"))
    }

    // MARK: - Checksum path

    func testDifferingChecksumsUpdate() {
        XCTAssertTrue(decide(server: "sha-new", cached: "sha-old"))
    }

    func testMatchingChecksumsDoNotUpdate() {
        XCTAssertFalse(decide(server: "sha-same", cached: "sha-same"))
    }

    /// The checksum reflects content and the version does not, so a matching checksum wins even
    /// when the version strings disagree — no needless re-download.
    func testMatchingChecksumWinsOverDifferingVersions() {
        XCTAssertFalse(decide(server: "sha-same", cached: "sha-same",
                              serverVersion: "01/25-2", currentVersion: "01/25"))
    }

    /// Self-healing: once the redundant download stores a checksum, the next check settles.
    func testRedundantDownloadHappensAtMostOnce() {
        XCTAssertTrue(decide(server: "sha-new", cached: nil), "first check: unknown → update")
        XCTAssertFalse(decide(server: "sha-new", cached: "sha-new"), "after caching: settled")
    }

    // MARK: - No checksum from the server (premium without entitlement)

    func testNoChecksum_sameVersion_doesNotUpdate() {
        XCTAssertFalse(decide(server: nil, cached: nil,
                              serverVersion: "01/25", currentVersion: "01/25"))
    }

    func testNoChecksum_newerVersion_updates() {
        XCTAssertTrue(decide(server: nil, cached: nil,
                             serverVersion: "2.1e-2", currentVersion: "2.1e"))
    }

    /// A stale *cached* checksum must not be consulted when the server offers none — the version
    /// string is the only comparable signal in that branch.
    func testNoServerChecksum_ignoresCachedChecksum() {
        XCTAssertFalse(decide(server: nil, cached: "sha-stale",
                              serverVersion: "01/25", currentVersion: "01/25"))
    }

    // MARK: - Nothing cached

    func testEmptyCurrentVersionAlwaysUpdates() {
        XCTAssertTrue(decide(server: nil, cached: nil,
                             serverVersion: "01/25", currentVersion: ""))
    }

    /// An empty local version with a server checksum still updates, via the checksum branch.
    func testEmptyCurrentVersionWithServerChecksumUpdates() {
        XCTAssertTrue(decide(server: "sha-new", cached: nil,
                             serverVersion: "01/25", currentVersion: ""))
    }

    // MARK: - Real version strings from the fleet

    /// The suffix scheme has to compare correctly for every format in the fleet, including the
    /// PS28's language-marked revisions where `e`/`f` is the language, not a revision.
    func testFleetVersionFormatsAllDetectTheBump() {
        for (old, new) in [("01/25", "01/25-2"), ("10/21", "10/21-2"),
                           ("10/22", "10/22-2"), ("2.1e", "2.1e-2"), ("2.1f", "2.1f-2")] {
            XCTAssertTrue(decide(server: nil, cached: nil, serverVersion: new, currentVersion: old),
                          "\(old) → \(new) must be detected as an update")
            XCTAssertFalse(decide(server: nil, cached: nil, serverVersion: new, currentVersion: new),
                           "\(new) → \(new) must not re-download")
        }
    }
}
