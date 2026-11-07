import CoreLocation
import XCTest
@testable import AeroCheck

/// The DABS against the airspace (a13, a14), and the file the server publishes.
@MainActor
final class ActivationTests: XCTestCase {
    private let day = "2026-11-04"
    /// 12:00 UTC on that day.
    private let noon = Date(timeIntervalSince1970: 1_793_793_600)

    private func limit(_ raw: String, _ ft: Int, _ ref: String) -> ActivationFile.Limit { .init(raw: raw, ft: ft, ref: ref) }

    private func area(_ id: String, windows: [[String]] = [["06:30", "21:00"]]) -> ActivationFile.Area {
        .init(id: id, notam: "W1/26", windowsUtc: windows, lower: limit("GND", 0, "GND"), upper: limit("2300m / 7500ft", 7500, "MSL"))
    }

    private func file(areas: [ActivationFile.Area] = [], temp: [ActivationFile.TempArea] = []) -> ActivationFile {
        .init(v: 1, date: day, version: 3, generatedUtc: "2026-11-04T11:45:00Z", areas: areas, tempAreas: temp)
    }

    private func board(_ file: ActivationFile?, at now: Date? = nil) -> ActivationBoard {
        ActivationBoard(files: file.map { [$0.date: $0] } ?? [:], now: now ?? noon)
    }

    private func airspace(_ name: String, _ type: AirspaceTypeCategory = .restricted, country: String = "CH") -> Airspace {
        let ring = [[7.0, 47.0], [7.1, 47.0], [7.1, 47.1], [7.0, 47.1], [7.0, 47.0]]
        return Airspace(id: name, name: name, type: type.rawValue, icaoClass: nil, country: country,
                        upperCeiling: AltitudeLimit(value: 15500, unit: 1, referenceDatum: 1),
                        lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
                        geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil, frequencies: nil)
    }

    func testListedAndInsideItsWindowIsActive() {
        XCTAssertTrue(board(file(areas: [area("LSR14")])).isActive(airspace("LSR14 SAENTIS")))
    }

    func testAMatchIsTheWholeId() {
        XCTAssertFalse(board(file(areas: [area("LSR1")])).isActive(airspace("LSR14 SAENTIS")))
    }

    func testAFreshFileThatDoesntListAnAreaFadesIt() {
        let b = board(file(areas: [area("LSR7")]))
        XCTAssertEqual(b.status(of: airspace("LSR14 SAENTIS")), .notListed)
        XCTAssertFalse(b.isActive(airspace("LSR14 SAENTIS")))
    }

    func testNoFileCountsEveryAreaAsActive() {
        let b = board(nil)
        XCTAssertFalse(b.isLoaded)
        XCTAssertTrue(b.isActive(airspace("LSR14 SAENTIS")))
    }

    func testYesterdaysFileCountsAsNone() {
        let b = board(file(areas: []), at: noon.addingTimeInterval(24 * 3600))
        XCTAssertFalse(b.isLoaded)
        XCTAssertTrue(b.isActive(airspace("LSR14 SAENTIS")))
    }

    func testTheSwissDayDecidesNotUTC() {
        // 23:30 UTC on the 4th is the 5th in Zurich
        XCTAssertEqual(ActivationBoard.dayString(noon.addingTimeInterval(11.5 * 3600)), "2026-11-05")
    }

    func testOutsideSwitzerlandEveryAreaCountsAsActive() {
        XCTAssertTrue(board(file()).isActive(airspace("LFR45 X", country: "FR")))
    }

    func testAControlledAirspaceIsNeverFaded() {
        XCTAssertTrue(board(file()).isActive(airspace("CTR ZURICH", .ctr)))
    }

    func testOutsideItsWindowItWaits() {
        let b = board(file(areas: [area("LSR7", windows: [["14:00", "15:00"]])]))
        XCTAssertFalse(b.isActive(airspace("LSR7 HONGRIN")))
    }

    func testTenMinutesBeforeItsWindowItCounts() {
        let b = board(file(areas: [area("LSR7", windows: [["12:05", "15:00"]])]))
        XCTAssertTrue(b.isActive(airspace("LSR7 HONGRIN")))
    }

    func testTheSecondWindowCounts() {
        let b = board(file(areas: [area("LSR7", windows: [["06:00", "07:00"], ["11:00", "13:00"]])]))
        XCTAssertTrue(b.isActive(airspace("LSR7 HONGRIN")))
    }

    func testAppliedTakesTheBulletinsLimitsAndDropsTheRest() {
        let out = board(file(areas: [area("LSR7")])).applied([airspace("LSR7 HONGRIN"), airspace("LSR14 SAENTIS"), airspace("TMA", .tma)])
        XCTAssertEqual(out.map(\.name), ["LSR7 HONGRIN", "TMA"])
        XCTAssertEqual(out[0].upperCeiling.value, 7500)
    }

    func testAFlightLevelReadsAsOne() {
        let upper = limit("FL130", 13000, "STD").altitudeLimit
        XCTAssertEqual(upper.unit, 6)
        XCTAssertEqual(upper.value, 130)
    }

    private func temp(windows: [[String]] = [["11:00", "15:00"]]) -> ActivationFile.TempArea {
        .init(notam: "W2929/26", centre: [46.5, 7.4], radiusNm: 4, kind: "R", name: "ST. STEPHAN", windowsUtc: windows,
              lower: limit("GND", 0, "GND"), upper: limit("2750m / 9000ft", 9000, "MSL"))
    }

    func testATemporaryAreaIsACircleOnEveryMap() throws {
        let circle = try XCTUnwrap(board(file(temp: [temp()])).tempAirspaces.first)
        XCTAssertEqual(circle.airspaceType, .restricted)
        XCTAssertTrue(circle.containsPoint(CLLocationCoordinate2D(latitude: 46.5, longitude: 7.4)))
        XCTAssertFalse(circle.containsPoint(CLLocationCoordinate2D(latitude: 46.6, longitude: 7.4)))
    }

    func testATemporaryAreaCountsOnlyInItsWindow() {
        XCTAssertEqual(board(file(temp: [temp()])).applied([]).count, 1)
        XCTAssertEqual(board(file(temp: [temp(windows: [["20:00", "21:00"]])])).applied([]).count, 0)
    }

    func testAFadedAreaGetsNoTagAndNoAheadState() {
        let b = board(file())
        let here = CLLocationCoordinate2D(latitude: 47.05, longitude: 7.05)
        let area = AirspaceAheadArea.make(at: here, trackDeg: 0, groundSpeedKt: 100)
        XCTAssertTrue(AirspaceRelevance.tags(in: b.applied([airspace("LSR7 HONGRIN")]), area: area, altitudeFt: 3000,
                                             verticalSpeedFpm: 0).isEmpty)
    }

    func testTheCardNamesTheSource() {
        XCTAssertEqual(board(file()).sourceText, "DABS v3, 12:45")
        XCTAssertNotNil(board(file()).note(for: airspace("LSR7 HONGRIN")))
        XCTAssertNil(board(nil).note(for: airspace("LSR7 HONGRIN")))
        XCTAssertNil(board(file()).note(for: airspace("TMA", .tma)))
    }

    // MARK: The service

    func testItDecodesTheServersFile() throws {
        let json = """
        {"v":1,"source":"DABS","date":"2026-11-04","version":3,"generatedUtc":"2026-11-04T11:45:00Z",
         "fetchedUtc":"x","sourceSha256":"y","flags":[],"textOnly":[],
         "areas":[{"id":"LSR7","notam":"W1/26","windowsUtc":[["06:30","21:00"]],
                   "lower":{"raw":"GND","ft":0,"ref":"GND"},"upper":{"raw":"FL130","ft":13000,"ref":"STD"},
                   "changed":true,"text":"R-AREA"}],
         "tempAreas":[]}
        """
        let decoded = try JSONDecoder().decode(ActivationFile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.areas.first?.id, "LSR7")
    }

    private func service(_ body: @escaping (URL) throws -> Data) -> ActivationService {
        ActivationService(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                          fetch: { try body($0) }, now: { self.noon })
    }

    func testARefreshKeepsTodaysFile() async throws {
        let body = try JSONEncoder().encode(file())
        let s = service { url in
            guard url.lastPathComponent == "\(self.day).json" else { throw URLError(.fileDoesNotExist) }
            return body
        }
        await s.refresh()
        XCTAssertTrue(s.board.isLoaded)
    }

    func testAFailedFetchLeavesTheFileItHad() async {
        let s = service { _ in throw URLError(.notConnectedToInternet) }
        s.seedForTesting([day: file()])
        await s.refresh()
        XCTAssertTrue(s.board.isLoaded)
    }

    func testAFileOfAnotherDayIsRefused() async throws {
        let wrong = try JSONEncoder().encode(ActivationFile(v: 1, date: "2026-11-03", version: 1, generatedUtc: "x", areas: [], tempAreas: []))
        let s = service { _ in wrong }
        await s.refresh()
        XCTAssertFalse(s.board.isLoaded)
    }
}
