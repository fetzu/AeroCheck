import XCTest
@testable import AeroCheck

/// iOS's daily reports kept on the device for Developer options (MetricKit, decision q5, 6.10.0).
final class MetricReportsTests: XCTestCase {
    func testTheNewestFourteenOfEachKindStayOldestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MetricReportsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let reports = MetricReports(folder: folder)
        let day0 = Date(timeIntervalSince1970: 1_793_491_200)   // 2026-11-01T00:00:00Z
        for day in 0..<20 {
            reports.keep(Data("{\"day\":\(day)}".utf8), kind: .metrics, ending: day0.addingTimeInterval(Double(day) * 86_400))
        }
        reports.keep(Data("{}".utf8), kind: .diagnostics, ending: day0)

        let metrics = reports.files(of: .metrics)
        XCTAssertEqual(metrics.count, MetricReports.kept)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(metrics.first), encoding: .utf8), "{\"day\":6}", "the oldest went")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(metrics.last), encoding: .utf8), "{\"day\":19}")
        XCTAssertEqual(reports.files(of: .diagnostics).count, 1, "each kind keeps its own")
        XCTAssertEqual(reports.files().count, MetricReports.kept + 1)
        XCTAssertFalse(metrics.contains { $0.lastPathComponent.contains(":") }, "no colon in a file name")
    }
}
