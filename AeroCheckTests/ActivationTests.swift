import CoreLocation
import MapKit
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

    // MARK: - Abroad, from the NOTAMs (6.10.0)

    private func limitFt(_ ft: Int, _ ref: String) -> ActivationFile.Limit { .init(raw: "\(ft)", ft: ft, ref: ref) }

    /// A Czech tempo R area, 3 NM around a point near Karlovy Vary, 08:00 to 15:00 on the test's day.
    private func czechArea(areas: [String] = [], shapes: [NotamActivation.Shape]? = nil, kind: NotamActivation.Kind = .restricted,
                           from: String = "08:00", to: String = "15:00", exact: Bool = true, upper: Int = 4000) -> NotamArea {
        let window = NotamActivation.Window(start: NotamTime.date("\(day)T\(from):00Z")!, end: NotamTime.date("\(day)T\(to):00Z")!)
        let activation = NotamActivation(kind: kind, areas: areas,
                                         shapes: shapes ?? [.circle(latitude: 50.2, longitude: 12.9, radiusNm: 3)],
                                         windows: [window], exact: exact, lower: limitFt(0, "GND"), upper: limitFt(upper, "MSL"))
        let notam = Notam(id: "N1", number: "B1/26", location: "LKAA", schedule: exact ? nil : "SR-SS", text: "TEMPO RESTRICTED AREA",
                          kind: .airspace, activation: activation)
        return NotamArea(notam: notam, activation: activation, country: "CZ")
    }

    private func abroad(_ areas: [NotamArea], known: Set<String> = [], at now: Date? = nil) -> ActivationBoard {
        let moment = now ?? noon
        return ActivationBoard(files: [:], now: moment, notams: NotamAreaSet(areas: areas, knownAreas: known, now: moment))
    }

    func testANotamsOwnAreaIsAnRAreaWhileActive() throws {
        let b = abroad([czechArea()])
        let drawn = try XCTUnwrap(b.drawnTempAirspaces(in: nil).first)
        XCTAssertEqual(drawn.airspaceType, .restricted)
        XCTAssertEqual(drawn.mapKind, .restrictive)
        XCTAssertEqual(drawn.name, "R NOTAM B1/26")
        XCTAssertEqual(drawn.upperCeiling.value, 4000)
        XCTAssertTrue(b.isActive(drawn))
        XCTAssertEqual(b.applied([]).map(\.id), [drawn.id])
    }

    func testANotamsAreaIsDrawnFadedBeforeItsWindowAndCountsTenMinutesAhead() throws {
        let early = abroad([czechArea()], at: noon.addingTimeInterval(-5 * 3600)) // 07:00
        let drawn = try XCTUnwrap(early.drawnTempAirspaces(in: nil).first)
        XCTAssertFalse(early.isActive(drawn))
        XCTAssertTrue(early.applied([]).isEmpty)
        let soon = abroad([czechArea()], at: noon.addingTimeInterval(-4 * 3600 - 5 * 60)) // 07:55
        XCTAssertTrue(soon.isActive(try XCTUnwrap(soon.drawnTempAirspaces(in: nil).first)))
    }

    func testANotamsAreaPastItsWindowOrBeyondTwelveHoursIsNotDrawn() {
        XCTAssertTrue(abroad([czechArea()], at: noon.addingTimeInterval(4 * 3600)).drawnTempAirspaces(in: nil).isEmpty) // 16:00
        XCTAssertTrue(abroad([czechArea(from: "23:00", to: "23:30")], at: noon.addingTimeInterval(-13 * 3600))
            .drawnTempAirspaces(in: nil).isEmpty)
    }

    func testANotamNamingAnAreaTheDeviceHasDrawsNothingAndPutsItsTimesOnThatCard() {
        let area = czechArea(areas: ["LKTSA2B"])
        let b = abroad([area], known: ["LKTSA2B"])
        XCTAssertTrue(b.drawnTempAirspaces(in: nil).isEmpty)
        let tsa = airspace("LKTSA2B BREZINA", .tsa, country: "CZ")
        XCTAssertEqual(b.note(for: tsa), L10n.Nav.dabsActive("08:00–15:00", "NOTAM B1/26"))
        // Never faded abroad: an area keeps counting as active, NOTAM or not
        XCTAssertTrue(b.isActive(tsa))
        XCTAssertTrue(abroad([czechArea(areas: ["LKTSA2B"])], known: ["LKTSA2B"], at: noon.addingTimeInterval(4 * 3600))
            .isActive(tsa))
    }

    func testANotamNamingAnAreaTheDeviceLacksDrawsItsShapeUnderThatName() throws {
        let b = abroad([czechArea(areas: ["LKR9"])], known: [])
        XCTAssertEqual(try XCTUnwrap(b.drawnTempAirspaces(in: nil).first).name, "LKR9 NOTAM B1/26")
    }

    func testAnAreaNoNotamNamesAbroadStaysActiveWithNoNote() {
        let b = abroad([czechArea()])
        let other = airspace("ED-R54 LEHNIN", country: "DE")
        XCTAssertTrue(b.isActive(other))
        XCTAssertNil(b.note(for: other))
        XCTAssertEqual(b.applied([other]).first?.id, other.id)
    }

    func testSwitzerlandKeepsTheDabsEvenWhenADesignatorMatches() {
        let b = abroad([czechArea(areas: ["LSR14"])], known: [])
        XCTAssertNil(b.note(for: airspace("LSR14 SAENTIS")))
    }

    func testAPolygonAndADangerAreaKeepTheirKind() throws {
        let ring = [[12.9, 50.2], [13.0, 50.2], [13.0, 50.3], [12.9, 50.2]]
        let b = abroad([czechArea(shapes: [.polygon(ring)], kind: .danger)])
        let drawn = try XCTUnwrap(b.drawnTempAirspaces(in: nil).first)
        XCTAssertEqual(drawn.airspaceType, .danger)
        XCTAssertEqual(drawn.polygonCoordinates.count, 4)
        XCTAssertEqual(drawn.name, "D NOTAM B1/26")
    }

    func testOnlyTheAreasOverTheRegionAreAdded() {
        let b = abroad([czechArea()])
        let far = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47, longitude: 7),
                                     span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        let near = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 50.2, longitude: 12.9),
                                      span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        XCTAssertTrue(b.drawnTempAirspaces(in: far).isEmpty)
        XCTAssertTrue(b.applied([], region: far).isEmpty)
        XCTAssertEqual(b.applied([], region: near).count, 1)
    }

    func testAnUnreadScheduleShowsItsWordsAfterTheSpan() throws {
        let b = abroad([czechArea(exact: false)])
        let drawn = try XCTUnwrap(b.drawnTempAirspaces(in: nil).first)
        XCTAssertEqual(b.note(for: drawn), L10n.Nav.notamActive("08:00–15:00, SR-SS"))
    }

    func testANotamsAreaOnTheCardHasItsTimesOnceAndNoWordOfTheDabs() throws {
        let b = abroad([czechArea()])
        let drawn = try XCTUnwrap(b.drawnTempAirspaces(in: nil).first)
        let stack = try XCTUnwrap(AirspaceStack.make(at: CLLocationCoordinate2D(latitude: 50.2, longitude: 12.9), from: [drawn],
                                                     altitudeFt: 3000, board: b))
        XCTAssertEqual(stack.rows.first?.note, L10n.Nav.notamActive("08:00–15:00"))
        XCTAssertFalse(stack.mentionsBulletin)
        // A Swiss area's DABS note still says the DABS doesn't replace the NOTAMs
        let swiss = board(file(areas: [area("LSR14")]))
        let saentis = airspace("LSR14 SAENTIS")
        let card = try XCTUnwrap(AirspaceStack.make(at: CLLocationCoordinate2D(latitude: 47.05, longitude: 7.05), from: [saentis],
                                                    altitudeFt: 3000, board: swiss))
        XCTAssertTrue(card.mentionsBulletin)
    }

    func testAnAglCeilingKeepsItsHeight() {
        let agl = limit("150M AGL", 493, "GND").altitudeLimit
        XCTAssertEqual([agl.value, agl.unit, agl.referenceDatum], [493, 1, 0])
        let ground = limit("GND", 0, "GND").altitudeLimit
        XCTAssertEqual([ground.value, ground.unit, ground.referenceDatum], [0, 1, 0])
    }

    func testAnAreaTheNotamDrawsGetsATagAndAirspaceAhead() throws {
        // Westbound at 3000 ft towards the circle's eastern edge, 100 kt: in it within three minutes
        let b = abroad([czechArea()])
        let airspaces = b.applied([])
        let position = CLLocationCoordinate2D(latitude: 50.2, longitude: 12.9 + 7.0 / (60 * cos(50.2 * .pi / 180)))
        let finding = try XCTUnwrap(AirspaceAheadFinding.first(in: airspaces, from: position, trackDeg: 270, groundSpeedKt: 100,
                                                               altitudeFt: 3000))
        XCTAssertEqual(finding.name, "R NOTAM B1/26")
        let area = AirspaceAheadArea.make(at: position, trackDeg: 270, groundSpeedKt: 100)
        XCTAssertEqual(AirspaceRelevance.tags(in: airspaces, area: area, altitudeFt: 3000, verticalSpeedFpm: 0).first?.airspace.name,
                       "R NOTAM B1/26")
    }

    func testTheServiceBoardLeavesTheNotamsOutOfADryRunAndSwitzerland() {
        // Built from the NOTAM files: Switzerland's file never adds an area (the DABS has them)
        let ch = NotamFile(country: "CH", notams: [czechArea().notam])
        let cz = NotamFile(country: "CZ", notams: [czechArea().notam])
        let notams = NotamService(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                  fetch: { _, _ in .init() }, now: { self.noon })
        notams.seedForTesting(index: NotamIndex(countries: ["CH": .init(file: "ch.json"), "CZ": .init(file: "cz.json")]),
                              files: ["ch.json": ch, "cz.json": cz])
        XCTAssertEqual(notams.areaActivations.map(\.country), ["CZ"])
        let service = ActivationService(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                        fetch: { _ in Data() }, now: { self.noon })
        XCTAssertEqual(service.board(knownAreas: [], notams: notams).drawnTempAirspaces(in: nil).count, 1)
    }
}
