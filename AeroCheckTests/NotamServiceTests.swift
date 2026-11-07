import CoreLocation
import XCTest
@testable import AeroCheck

/// The files on the device: what's fetched and when, what stays for the flight, and what goes.
@MainActor
final class NotamServiceTests: XCTestCase {
    private let start = NotamTime.date("2026-11-06T07:15:00Z")!
    private var moment = NotamTime.date("2026-11-06T07:15:00Z")!
    private var requests: [String] = []
    /// The ETag each last request sent.
    private var conditional: [String: String?] = [:]
    private var failing = false
    /// The server, by file name.
    private var server: [String: Any] = [:]

    private func notam(_ id: String, at location: String = "LSZQ") -> [String: Any] {
        ["id": id, "number": "A\(id)/26", "location": location, "text": "TEXT \(id)"]
    }

    private func publish(updated: String = "2026-11-06T07:10:00Z", ch: [[String: Any]] = [], noList: [String] = ["AT"], note: Any = NSNull()) {
        server["index.json"] = ["v": 1, "generatedUtc": updated, "noList": noList,
                                "countries": ["CH": ["file": "ch.json", "count": ch.count, "updatedUtc": updated, "note": note],
                                              "FR": ["file": "fr.json", "updatedUtc": updated]]] as [String: Any]
        server["ch.json"] = ["v": 1, "country": "CH", "updatedUtc": updated, "notams": ch] as [String: Any]
        server["fr.json"] = ["v": 1, "country": "FR", "updatedUtc": updated, "notams": [notam("90", at: "LFGA")]] as [String: Any]
    }

    /// Answers as the server does: a file by its ETag, a 304 when the app's still stands; a file's ETag is its content's.
    private func service(folder: URL? = nil) -> NotamService {
        NotamService(folder: folder ?? makeTestDirectory(), fetch: { [unowned self] url, etag in
            let name = url.lastPathComponent
            requests.append(name)
            conditional[name] = etag
            if failing { throw URLError(.notConnectedToInternet) }
            guard let body = server[name] else { throw URLError(.fileDoesNotExist) }
            let data = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            if name == "index.json" { return .init(body: data) }
            let tag = "\"\(fileTag(name))\""
            return etag == tag ? .init(body: nil, etag: tag) : .init(body: data, etag: tag)
        }, now: { [unowned self] in moment })
    }

    /// Stands for the file's content: what `publish` changes.
    private func fileTag(_ name: String) -> Int {
        ((server[name] as? [String: Any])?["notams"] as? [[String: Any]])?.map { $0["id"] as? String ?? "" }.joined().hashValue ?? 0
    }

    func testItFetchesTheIndexAndOnlyTheRoutesCountries() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(requests, ["index.json", "ch.json"])
        XCTAssertTrue(s.hasList("CH"))
        XCTAssertFalse(s.hasList("FR"), "listed, but no flight asked for it")
        XCTAssertFalse(s.hasList("AT"))
        XCTAssertEqual(s.notams(at: "LSZQ").map(\.id), ["1"])
    }

    func testNothingFetchesInFlightThoughTheCopyStays() async {
        let folder = makeTestDirectory()
        publish(ch: [notam("1")])
        let first = service(folder: folder)
        await first.refreshIfNeeded(countries: ["CH"], onGround: true)
        requests = []
        // A relaunch in the air: the copy comes back from the disk, and no signal is asked for.
        let relaunched = service(folder: folder)
        await relaunched.refreshIfNeeded(countries: ["CH"], onGround: false)
        XCTAssertEqual(requests, [])
        XCTAssertEqual(relaunched.notams(at: "LSZQ").map(\.id), ["1"])
    }

    func testAPageOpenedAgainSoonFetchesNothing() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        requests = []
        moment = start.addingTimeInterval(NotamService.minInterval - 1)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(requests, [])
        moment = start.addingTimeInterval(NotamService.minInterval + 1)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(requests, ["index.json", "ch.json"], "the index and a conditional fetch")
        XCTAssertNotNil(conditional["ch.json"] ?? nil, "with the ETag it was given")
    }

    func testANewCountryDoesntWaitForTheInterval() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        requests = []
        await s.refreshIfNeeded(countries: ["FR"], onGround: true)
        XCTAssertEqual(requests, ["index.json", "ch.json", "fr.json"], "the one on the device only asked whether it changed")
        XCTAssertNotNil(conditional["ch.json"] ?? nil)
        XCTAssertNil(conditional["fr.json"] ?? nil, "nothing to compare yet")
        XCTAssertTrue(s.hasList("CH"), "the first stays")
    }

    func testTheRefreshButtonHasItsOwnLimit() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], force: true, onGround: true)
        requests = []
        moment = start.addingTimeInterval(5)
        await s.refreshIfNeeded(countries: ["CH"], force: true, onGround: true)
        XCTAssertEqual(requests, [])
        moment = start.addingTimeInterval(NotamService.minForcedInterval + 1)
        await s.refreshIfNeeded(countries: ["CH"], force: true, onGround: true)
        XCTAssertEqual(requests, ["index.json", "ch.json"])
    }

    func testAFailedRefreshKeepsTheCopyAndSaysSo() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        failing = true
        moment = start.addingTimeInterval(3 * 3600)
        await s.refreshIfNeeded(countries: ["CH"], force: true, onGround: true)
        XCTAssertEqual(s.notams(at: "LSZQ").map(\.id), ["1"])
        let copy = s.copyState(countries: ["CH"])
        XCTAssertTrue(copy.couldNotRefresh)
        XCTAssertTrue(copy.isOld(now: moment))
        failing = false
        moment = start.addingTimeInterval(3 * 3600 + 60)
        await s.refreshIfNeeded(countries: ["CH"], force: true, onGround: true)
        XCTAssertFalse(s.copyState(countries: ["CH"]).couldNotRefresh)
    }

    func testTheFirstCopyIsTheBaselineAndWhatComesLaterIsNew() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        let tick = start.addingTimeInterval(60)
        XCTAssertLessThan(s.firstSeen["1"] ?? .distantFuture, tick)
        publish(updated: "2026-11-06T10:00:00Z", ch: [notam("1"), notam("2")])
        moment = start.addingTimeInterval(4 * 3600)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(s.firstSeen["2"], moment)
        XCTAssertLessThan(s.firstSeen["1"] ?? .distantFuture, tick, "still the baseline")
    }

    func testACountryThatLosesItsListLosesItsFile() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        publish(ch: [notam("1")], noList: ["AT", "CH"])
        moment = start.addingTimeInterval(NotamService.minInterval + 1)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertFalse(s.hasList("CH"))
        XCTAssertTrue(s.notams(at: "LSZQ").isEmpty, "no row for it on a card")
    }

    func testAFieldsNotamsLeaveOutThoseOverFirstStartedFirst() {
        let s = service()
        let over = Notam(id: "1", number: "A1/26", location: "LSZQ", end: start.addingTimeInterval(-1), text: "OVER")
        let later = Notam(id: "2", number: "A2/26", location: "LSZQ", start: start.addingTimeInterval(3600), text: "LATER")
        let now = Notam(id: "3", number: "A3/26", location: "LSZQ", start: start.addingTimeInterval(-3600), text: "NOW")
        s.seedForTesting(index: NotamIndex(countries: ["CH": .init(file: "ch.json")]), files: ["ch.json": NotamFile(notams: [over, later, now])])
        XCTAssertEqual(s.notams(at: "lszq", now: start).map(\.id), ["3", "2"])
        XCTAssertTrue(s.notams(at: "LSGC", now: start).isEmpty)
    }

    func testAMissingOrNewerSchemaNeverReplacesTheCopy() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        server["index.json"] = ["v": 2, "countries": [:]] as [String: Any]
        moment = start.addingTimeInterval(NotamService.minInterval + 1)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertTrue(s.hasList("CH"))
        XCTAssertTrue(s.couldNotRefresh)
    }

    func testACountrysNoteComesFromTheIndex() async {
        publish(ch: [notam("1")], note: ["en": "Switzerland: obstacles are often missing here."])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(s.note(for: "CH"), "Switzerland: obstacles are often missing here.")
        XCTAssertNil(s.note(for: "FR"))
    }

    /// The index's time moves at every run; a 304 says the file on the device is that fresh, whatever its own time says.
    func testTheCopysAgeIsTheIndexsForTheCountryAcrossA304() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(s.copyState(countries: ["CH"]).time, NotamTime.date("2026-11-06T07:10:00Z"))
        let unchanged = server["ch.json"]
        publish(updated: "2026-11-06T09:00:00Z", ch: [notam("1")])
        server["ch.json"] = unchanged
        moment = start.addingTimeInterval(2 * 3600)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        XCTAssertEqual(s.copyState(countries: ["CH"]).time, NotamTime.date("2026-11-06T09:00:00Z"))
        XCTAssertEqual(s.files["ch.json"]?.updatedUtc, NotamTime.date("2026-11-06T07:10:00Z"), "the 304 kept the file")
    }

    func testAFileThatFailsKeepsItsOwnAgeThoughTheIndexMoved() async {
        publish(ch: [notam("1")])
        let s = service()
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        publish(updated: "2026-11-06T09:00:00Z", ch: [notam("1"), notam("2")])
        server["ch.json"] = nil
        moment = start.addingTimeInterval(2 * 3600)
        await s.refreshIfNeeded(countries: ["CH"], onGround: true)
        let copy = s.copyState(countries: ["CH"])
        XCTAssertEqual(copy.time, NotamTime.date("2026-11-06T07:10:00Z"))
        XCTAssertTrue(copy.couldNotRefresh)
    }

    func testTheOldestCountryGivesTheCopysTime() async {
        publish(ch: [notam("1")])
        var index = server["index.json"] as? [String: Any]
        var countries = index?["countries"] as? [String: [String: Any]]
        countries?["FR"]?["updatedUtc"] = "2026-11-06T02:00:00Z"
        index?["countries"] = countries
        server["index.json"] = index
        let s = service()
        await s.refreshIfNeeded(countries: ["CH", "FR"], onGround: true)
        XCTAssertEqual(s.copyState(countries: ["CH", "FR"]).time, NotamTime.date("2026-11-06T02:00:00Z"), "the amber age of a daily file")
        XCTAssertEqual(s.copyState(countries: ["CH"]).time, NotamTime.date("2026-11-06T07:10:00Z"))
    }

    func testANotamPastItsEndLeavesTheListAndTheMapBetweenRuns() {
        let s = service()
        let over = Notam(id: "1", number: "A1/26", location: "LSZQ", end: start.addingTimeInterval(-1), text: "OVER")
        let on = Notam(id: "2", number: "A2/26", location: "LSZQ", end: start.addingTimeInterval(60), text: "ON")
        s.seedForTesting(index: NotamIndex(countries: ["CH": .init(file: "ch.json")]), files: ["ch.json": NotamFile(notams: [over, on])])
        XCTAssertEqual(s.notams(in: ["CH"]).map(\.id), ["2"])
        XCTAssertEqual(s.allNotams.map(\.id), ["2"])
        moment = start.addingTimeInterval(61)
        XCTAssertTrue(s.notams(in: ["CH"]).isEmpty)
    }

    /// Glère, on the Doubs: the coarse borders put it in no country at all, and the chip must still know where it is.
    func testAPointBetweenTheCoarseBordersStillHasACountry() {
        let glere = CLLocationCoordinate2D(latitude: 47.345151, longitude: 6.982395)
        XCTAssertTrue(CountryBoundaries.shared.countries(near: glere, bufferNm: 0).isEmpty, "if the asset improves, this test can go")
        XCTAssertFalse(NotamService.countries(at: glere).isEmpty)
        XCTAssertEqual(NotamService.countries(at: .init(latitude: 46.9, longitude: 7.5)), ["CH"], "inside, the exact answer")
    }

    func testLiechtensteinSharesSwitzerlandsFile() {
        let s = service()
        let index = NotamIndex(countries: ["CH": .init(file: "ch.json"), "LI": .init(file: "ch.json")])
        s.seedForTesting(index: index, files: ["ch.json": NotamFile(notams: [Notam(id: "1", number: "A1/26", location: "LSXV", text: "X")])])
        XCTAssertTrue(s.hasList("LI"))
        XCTAssertEqual(s.notams(in: ["CH", "LI"]).count, 1)
    }

    func testNoServiceReachesTheNetworkInATest() async {
        // The host is the app: the shared service, with no fetch of its own, stays quiet.
        await NotamService.shared.refreshIfNeeded(countries: ["CH"], force: true, onGround: true)
        XCTAssertFalse(NotamService.shared.isLoading)
    }
}
