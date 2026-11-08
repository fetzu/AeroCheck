import CoreLocation
import UIKit
import XCTest
@testable import AeroCheck

/// What the NOTAM tests share: a flight from Bressaucourt to Colmar, and NOTAMs to sort against it.
class NotamTestCase: XCTestCase {
    let noon = NotamTime.date("2026-11-06T12:00:00Z")!

    func flight(ceiling: Double? = 6500, aerodromes: [String: NotamFlight.Role] = ["LSZQ": .departure, "LFGA": .destination]) -> NotamFlight {
        // Bressaucourt to Colmar: north-north-east.
        NotamFlight(route: [.init(latitude: 47.39, longitude: 7.03, altitudeFt: 1400), .init(latitude: 47.65, longitude: 7.15, altitudeFt: 5500),
                            .init(latitude: 48.11, longitude: 7.36, altitudeFt: 700)],
                    aerodromes: aerodromes, start: noon, end: noon.addingTimeInterval(3 * 3600), ceilingFt: ceiling, label: "LSZQ → LFGA")
    }

    func notam(_ id: String, at location: String = "LFEE", lat: Double? = nil, lon: Double? = nil, radius: Double? = nil,
                       traffic: String? = "V", lower: Int = 0, upper: Int = 999, start: Date? = nil, end: Date? = nil,
                       kind: Notam.Kind = .other, number: String? = nil) -> Notam {
        Notam(id: id, number: number ?? "A\(id)/26", location: location, fir: "LFEE", traffic: traffic, lowerFl: lower, upperFl: upper, start: start,
              end: end, text: "TEXT \(id)", lat: lat, lon: lon, radiusNm: radius, kind: kind)
    }

    func onRoute(_ id: String, traffic: String? = "V", lower: Int = 0, start: Date? = nil, end: Date? = nil) -> Notam {
        var n = notam(id, traffic: traffic, lower: lower, start: start, end: end)
        n.lat = 47.75
        n.lon = 7.20
        return n
    }
}

/// The NOTAMs from our copy: the server's files as the app reads them, and the sort against the flight, in which nothing
/// disappears. (decided 6 Nov 2026)
final class NotamTests: NotamTestCase {
    // MARK: The files

    func testAnIndexReadsItsListsAndIgnoresNewKeys() throws {
        let json = """
        {"v":1,"generatedUtc":"2026-11-06T07:15:00Z","future":{"a":1},"noList":["AT","gb"],
         "countries":{"CH":{"file":"ch.json","count":321,"updatedUtc":"2026-11-06T07:10:00Z","note":null,"more":true},
                      "FR":{"file":"fr.json","note":{"en":"Gap.","fr":"Trou."}},"XX":"not an object"}}
        """
        let index = try JSONDecoder().decode(NotamIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.generatedUtc, NotamTime.date("2026-11-06T07:15:00Z"))
        XCTAssertEqual(Set(index.countries.keys), ["CH", "FR"], "a country that can't be read is left out")
        XCTAssertTrue(index.hasList("ch"))
        XCTAssertFalse(index.hasList("AT"), "in noList")
        XCTAssertFalse(index.hasList("GB"))
        XCTAssertFalse(index.hasList("SE"), "in neither list: never measured, the same")
        XCTAssertEqual(index.countries["FR"]?.note?.text(language: "fr"), "Trou.")
        XCTAssertEqual(index.countries["FR"]?.note?.text(language: "de"), "Gap.", "English when the language has none")
    }

    func testACountryInBothListsHasNoList() {
        let index = NotamIndex(countries: ["AT": .init(file: "at.json")], noList: ["AT"])
        XCTAssertFalse(index.hasList("AT"))
    }

    func testAMinimalNotamReadsWithSafeDefaultsAndABadOneIsLeftOut() throws {
        let json = """
        {"v":1,"country":"CH","updatedUtc":"2026-11-06T07:10:00.000Z","notams":[
          {"id":"1","number":"B1817/26","location":"lszq","text":"RWY CLSD","newKey":[1,2]},
          {"number":"no id"},
          {"id":"3","number":"B2/26","location":"LSAS","text":"X","lowerFl":"oops","kind":"weird","start":"not a date","end":null,
           "polygon":[[7.0,47.0],[7.1,47.0],[7.1,47.1]],"traffic":"IV","radiusNm":999,"lat":47.0,"lon":7.0}
        ]}
        """
        let file = try JSONDecoder().decode(NotamFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.notams.map(\.id), ["1", "3"])
        XCTAssertEqual(file.updatedUtc, NotamTime.date("2026-11-06T07:10:00Z"), "fractions read too")
        let first = file.notams[0]
        XCTAssertEqual(first.location, "LSZQ")
        XCTAssertEqual(first.lowerFl, 0)
        XCTAssertEqual(first.upperFl, 999)
        XCTAssertNil(first.end, "no end: permanent")
        XCTAssertNil(first.circle)
        XCTAssertEqual(file.notams[1].kind, .other, "a kind the app doesn't know")
        XCTAssertEqual(file.notams[1].lowerFl, 0, "a band it can't read counts from the ground")
        XCTAssertTrue(file.notams[1].isWholeRegion)
    }

    /// The server's fallbacks: "" for a string it doesn't have, IV and QXXXX, and `bytes` in the index.
    func testAnActivationReadsAndOneThatCantBeReadLeavesTheNotam() throws {
        let json = """
        {"v":1,"notams":[
         {"id":"1","number":"B1/26","location":"LKAA","text":"T","activation":{"kind":"R","areas":["lktsa2b"],
          "shapes":[{"centre":[50.2,12.9],"radiusNm":3},{"polygon":[[12.9,50.2],[13.0,50.2],[13.0,50.3],[12.9,50.2]]},{"centre":[99,1],"radiusNm":1}],
          "windowsUtc":[["2026-11-04T08:00:00Z","2026-11-04T15:00:00Z"],["bad","2026-11-04T15:00:00Z"]],"exact":true,
          "lower":{"raw":"GND","ft":0,"ref":"GND"},"upper":{"raw":"4000FT AMSL","ft":4000,"ref":"MSL"},"newKey":1}},
         {"id":"2","number":"B2/26","location":"LKAA","text":"T","activation":{"kind":"X","windowsUtc":[],"lower":{},"upper":{}}},
         {"id":"3","number":"B3/26","location":"LKAA","text":"T","activation":{"kind":"D","windowsUtc":[],
          "lower":{"raw":"GND","ft":0,"ref":"GND"},"upper":{"raw":"FL95","ft":9500,"ref":"STD"}}}
        ]}
        """
        let file = try JSONDecoder().decode(NotamFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.notams.map(\.number), ["B1/26", "B2/26", "B3/26"])
        let read = try XCTUnwrap(file.notams[0].activation)
        XCTAssertEqual(read.kind, .restricted)
        XCTAssertEqual(read.areas, ["LKTSA2B"])
        XCTAssertEqual(read.shapes.count, 2)
        XCTAssertEqual(read.windows.count, 1)
        XCTAssertTrue(read.exact)
        XCTAssertEqual(read.upper.ft, 4000)
        // An unknown kind, or no window: the NOTAM stays, without an area
        XCTAssertNil(file.notams[1].activation)
        XCTAssertNil(file.notams[2].activation)
    }

    /// A real copy, downloaded by hand: `TEST_RUNNER_AEROCHECK_NOTAM_COPY=<folder of <cc>.json>`. Skipped otherwise.
    /// Every activation the server wrote must read, every shape must draw, and every area must have a note.
    func testEveryActivationOfARealCopyReadsAndDraws() throws {
        guard let folder = ProcessInfo.processInfo.environment["AEROCHECK_NOTAM_COPY"] else {
            throw XCTSkip("No real copy given (TEST_RUNNER_AEROCHECK_NOTAM_COPY).")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".json") && $0 != "index.json" }
        XCTAssertFalse(names.isEmpty)
        var written = 0, read = 0, shapes = 0, drawn = 0
        let now = Date()
        for name in names {
            let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name))
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rawNotams = raw["notams"] as? [[String: Any]] ?? []
            written += rawNotams.filter { $0["activation"] != nil }.count
            let file = try JSONDecoder().decode(NotamFile.self, from: data)
            XCTAssertEqual(file.notams.count, rawNotams.count, "\(name): a NOTAM left out")
            for notam in file.notams {
                guard let activation = notam.activation else { continue }
                read += 1
                let area = NotamArea(notam: notam, activation: activation, country: file.country ?? "")
                shapes += activation.shapes.count
                drawn += area.airspaces.count
                XCTAssertNotNil(area.note(now: activation.windows[0].start), "\(name) \(notam.number): no note")
            }
            _ = NotamAreaSet(areas: file.notams.compactMap { notam in
                notam.activation.map { NotamArea(notam: notam, activation: $0, country: file.country ?? "") }
            }, knownAreas: [], now: now)
        }
        XCTAssertEqual(read, written, "an activation the app couldn't read")
        XCTAssertEqual(drawn, shapes, "a shape the app couldn't draw")
        print("real copy: \(names.count) files, \(read) activations, \(shapes) shapes")
    }

    func testAnAirspacesDesignatorReadsAsTheServerWritesANotamsAreas() {
        XCTAssertEqual(Airspace.designatorKey(of: "LF-R68B (AMC MANAGEABLE AERA)"), "LFR68B")
        XCTAssertEqual(Airspace.designatorKey(of: "EHTSA 16B AMSTERDAM/DAM SQUARE"), "EHTSA16B")
        XCTAssertEqual(Airspace.designatorKey(of: "EY-D 10"), "EYD10")
        XCTAssertEqual(Airspace.designatorKey(of: "LI TRA426 - FRANCAVILLA"), "LITRA426")
        XCTAssertEqual(Airspace.designatorKey(of: "EB-D26-ARDENNES 05"), "EBD26")
        XCTAssertEqual(Airspace.designatorKey(of: "TSA26B ARDENNES 04"), "TSA26B")
        XCTAssertEqual(Airspace.designatorKey(of: "ED-R37B_2 NORDHORN NOTAM"), "EDR37B")
        XCTAssertEqual(Airspace.designatorKey(of: "LSR11A ZUOZ/S-CHANF"), "LSR11A")
        XCTAssertNil(Airspace.designatorKey(of: "ZRT SAINT-DIZIER"))
    }

    func testTheServersEmptyStringsReadAsNothing() throws {
        let json = """
        {"v":1,"notams":[{"id":"1","number":"A1/26","location":"","fir":"","text":"","icao":"A1/26 NOTAMN","schedule":"","plain":"",
          "traffic":"IV","q":"QXXXX","scope":"","lat":47.75,"lon":7.2,"radiusNm":3,"kind":"other"}]}
        """
        let n = try XCTUnwrap(JSONDecoder().decode(NotamFile.self, from: Data(json.utf8)).notams.first)
        XCTAssertNil(n.fir)
        XCTAssertNil(n.plain, "no Spelled out")
        XCTAssertNil(n.schedule)
        XCTAssertEqual(n.shownText, "A1/26 NOTAMN", "the row is never blank")
        let index = try JSONDecoder().decode(NotamIndex.self, from: Data(#"{"v":1,"countries":{"CH":{"file":"ch.json","bytes":211283}},"noList":[]}"#.utf8))
        XCTAssertTrue(index.hasList("CH"))
    }

    func testAShapeWithoutACentreGivesTheCircleAroundItsCorners() throws {
        var n = notam("1")
        n.polygon = [[7.0, 47.0], [7.2, 47.0], [7.2, 47.2], [7.0, 47.2]]
        let circle = try XCTUnwrap(n.circle)
        XCTAssertEqual(circle.centre.latitude, 47.1, accuracy: 0.001)
        XCTAssertGreaterThan(circle.radiusNm, 7)
    }

    // MARK: The sort

    func testAtTheFlightsAerodromesWhateverItsGeometry() {
        let sorted = NotamSorter.sort([notam("1", at: "LFGA"), notam("2", at: "LSZQ")], for: flight())
        XCTAssertEqual(sorted.along.map(\.id), ["1", "2"], "the destination first")
        XCTAssertEqual(sorted.along[0].place, .aerodrome(.destination))
    }

    func testAPointWithinTenNauticalMilesOfTheRouteIsAlongIt() {
        let near = onRoute("1")
        var far = notam("2")
        far.lat = 47.75
        far.lon = 7.60   // about 15 NM east
        let sorted = NotamSorter.sort([near, far], for: flight())
        XCTAssertEqual(sorted.along.map(\.id), ["1"])
        XCTAssertEqual(sorted.away.map(\.id), ["2"], "away from the route, still there")
    }

    func testACircleCountsByItsEdge() {
        var far = notam("1")
        far.lat = 47.75
        far.lon = 7.60
        far.radiusNm = 8
        XCTAssertEqual(NotamSorter.sort([far], for: flight()).along.map(\.id), ["1"])
    }

    func testAWholeRegionRadiusNeverMakesANotamAlongTheFlight() {
        var fir = notam("1", at: "LSAS")
        fir.lat = 46.8
        fir.lon = 8.2
        fir.radiusNm = 999
        let sorted = NotamSorter.sort([fir], for: flight())
        XCTAssertTrue(sorted.along.isEmpty)
        XCTAssertTrue(sorted.away.isEmpty, "all over the country is not away from the route")
        XCTAssertEqual(sorted.region.map(\.id), ["1"])
        XCTAssertEqual(sorted.total, 1)
    }

    func testSeveralRegionsOnTheQLineMeanAWholeRegion() {
        var strike = notam("1", at: "LFBB", lat: 44.2, lon: 0.67, radius: 460)
        strike.fir = "LFXX"
        XCTAssertTrue(strike.isWholeRegion)
        XCTAssertEqual(NotamSorter.sort([strike], for: flight()).region.map(\.id), ["1"])
        var crane = strike
        crane.radiusNm = 2
        XCTAssertFalse(crane.isWholeRegion, "still a place")
        var wide = strike
        wide.fir = "LFEE"
        XCTAssertFalse(wide.isWholeRegion, "one region's wide circle stays a circle")
    }

    func testAWholeRegionNotamKeepsToTheFlightsTimeAndTraffic() {
        var later = notam("1", at: "LSAS", radius: 999, start: noon.addingTimeInterval(24 * 3600))
        later.lat = 46.8
        var ifr = notam("2", at: "LSAS", radius: 999, traffic: "I")
        ifr.lat = 46.8
        let sorted = NotamSorter.sort([later, ifr], for: flight())
        XCTAssertTrue(sorted.region.isEmpty)
        XCTAssertEqual(sorted.notDuring.map(\.id), ["1"])
        XCTAssertEqual(sorted.ifrOnly.map(\.id), ["2"])
    }

    func testAChecklistIsLeftOut() {
        var checklist = notam("1", at: "LSAS", radius: 999)
        checklist.q = "QKKKK"
        let sorted = NotamSorter.sort([checklist, onRoute("2")], for: flight())
        XCTAssertEqual(sorted.along.map(\.id), ["2"])
        XCTAssertEqual(sorted.total, 1)
        XCTAssertTrue(sorted.away.isEmpty)
    }

    func testTheSideOfTheRouteAndTheLegsAltitude() {
        var east = notam("1")
        east.lat = 47.75
        east.lon = 7.30
        var west = notam("2")
        west.lat = 47.75
        west.lon = 7.10
        let sorted = NotamSorter.sort([east, west], for: flight())
        guard case let .route(offset, side, altitude, _)? = sorted.along.first(where: { $0.id == "1" })?.place else { return XCTFail("no place") }
        XCTAssertEqual(side, .right, "the route goes north")
        XCTAssertEqual(altitude, 5500)
        XCTAssertGreaterThan(offset, 3)
        guard case let .route(_, other, _, _)? = sorted.along.first(where: { $0.id == "2" })?.place else { return XCTFail("no place") }
        XCTAssertEqual(other, .left)
    }

    func testTheRestGoInTheirGroupsWithNothingDropped() {
        let before = onRoute("1", start: noon.addingTimeInterval(-7200), end: noon.addingTimeInterval(-3600))
        let after = onRoute("2", start: noon.addingTimeInterval(24 * 3600))
        let high = onRoute("3", lower: 95)
        let ifr = onRoute("4", traffic: "I")
        let good = onRoute("5", traffic: "IV")
        let away = notam("6")
        let sorted = NotamSorter.sort([before, after, high, ifr, good, away], for: flight())
        XCTAssertEqual(sorted.along.map(\.id), ["5"])
        XCTAssertEqual(Set(sorted.notDuring.map(\.id)), ["1", "2"])
        XCTAssertEqual(sorted.above.map(\.id), ["3"])
        XCTAssertEqual(sorted.ifrOnly.map(\.id), ["4"])
        XCTAssertEqual(sorted.away.map(\.id), ["6"])
        XCTAssertEqual(sorted.total, 5, "All N: those that touch the route")
    }

    func testAnEqualBandAndAnEdgeTimeStillCount() {
        let edge = onRoute("1", lower: 65, end: noon)
        XCTAssertEqual(NotamSorter.sort([edge], for: flight()).along.map(\.id), ["1"], "FL 065 against 6500 ft, ending as the window opens")
    }

    func testWithNoPlannedAltitudeNothingGoesAbove() {
        XCTAssertEqual(NotamSorter.sort([onRoute("1", lower: 300)], for: flight(ceiling: nil)).along.map(\.id), ["1"])
    }

    func testKAndAMissingTrafficConcernAVFRFlight() {
        let sorted = NotamSorter.sort([onRoute("1", traffic: "K"), onRoute("2", traffic: nil), onRoute("3", traffic: "i")], for: flight())
        XCTAssertEqual(Set(sorted.along.map(\.id)), ["1", "2"])
        XCTAssertEqual(sorted.ifrOnly.map(\.id), ["3"])
    }

    func testANumberThatComesTwiceCountsOnce() {
        XCTAssertEqual(NotamSorter.sort([onRoute("1"), onRoute("1")], for: flight()).total, 1)
    }

    func testOneNotamForFiveRegionsIsOneRow() {
        // F2322/26 of 6 Nov 2026 comes once for each of France's five regions, under another id each time.
        let copies = ["LFRR", "LFBB", "LFMM", "LFEE", "LFFF"].enumerated().map { index, place -> Notam in
            var n = notam("\(index)", at: place, lat: 44.2, lon: 0.67, radius: 460, number: "F2322/26")
            n.fir = "LFXX"
            n.text = "DUE TO STRIKE"
            return n
        }
        let sorted = NotamSorter.sort(copies, for: flight())
        XCTAssertEqual(sorted.region.count, 1)
        XCTAssertEqual(sorted.region.first?.alsoAt, 4)
        XCTAssertEqual(NotamWords.title(try! XCTUnwrap(sorted.region.first)).where, "LFBB +4", "the first, for the same row every time")
    }

    func testARepeatedNotamTakesThePlaceThatMattersMost() {
        let far = notam("1", at: "LFBB", lat: 44, lon: 0, radius: 5, number: "A0001/26")
        var field = notam("2", at: "LFGA", number: "A0001/26")
        field.text = far.text
        let sorted = NotamSorter.sort([far, field], for: flight())
        XCTAssertEqual(sorted.along.map(\.notam.location), ["LFGA"])
        XCTAssertEqual(sorted.along.first?.place, .aerodrome(.destination))
        XCTAssertTrue(sorted.away.isEmpty)
    }

    func testTheSameNumberFromAnotherCountryIsAnotherNotam() {
        let a = notam("1", at: "LSZQ", number: "A0001/26"), b = notam("2", at: "LFGA", number: "A0001/26")
        XCTAssertEqual(NotamSorter.sort([a, b], for: flight()).along.count, 2)
    }

    func testInsideAWideCircleTheRouteIsInTheArea() {
        let wide = notam("1", at: "LFBB", lat: 44.2, lon: 0.67, radius: 460)
        guard case let .route(offset, side, _, _)? = NotamSorter.place(of: wide, in: flight()) else { return XCTFail("along the route") }
        XCTAssertEqual(offset, 0, "not 328 NM to the right")
        XCTAssertNil(side)
        // A small one keeps its distance: that crane is 3 NM to one side.
        let crane = notam("2", lat: 47.75, lon: 7.28, radius: 1)
        guard case let .route(near, nearSide, _, _)? = NotamSorter.place(of: crane, in: flight()) else { return XCTFail("along the route") }
        XCTAssertGreaterThan(near, 1)
        XCTAssertNotNil(nearSide)
    }

    func testTheStopAndTheAlternateCount() {
        let f = flight(aerodromes: ["LSZQ": .departure, "LFGA": .destination, "LFSB": .alternate, "LSGC": .stop])
        let sorted = NotamSorter.sort([notam("1", at: "LFSB"), notam("2", at: "LSGC"), notam("3", at: "LSZQ")], for: f)
        XCTAssertEqual(sorted.along.map(\.id), ["2", "1", "3"])
    }

    func testAFlightFromItsPlan() {
        let waypoints = [FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.39, longitude: 7.03), altitude: 1400),
                         FlightPlanWaypoint(name: "COLMAR", coordinate: .init(latitude: 47.7, longitude: 7.2), altitude: 4500),
                         FlightPlanWaypoint(name: "LFGA", coordinate: .init(latitude: 48.11, longitude: 7.36), altitude: 700, cumulativeEET: 1800)]
        var plan = FlightPlan(name: "T", waypoints: waypoints, aircraftTypeId: "wt9", aircraftRegistration: "F-HVXA", aircraftModelName: "WT9")
        plan.alternateAerodrome = " lfsb "
        let f = NotamFlight.make(plan: plan, departure: noon)
        XCTAssertEqual(f.aerodromes, ["LSZQ": .departure, "LFGA": .destination, "LFSB": .alternate])
        XCTAssertEqual(f.ceilingFt, 5500)
        XCTAssertEqual(f.start, noon.addingTimeInterval(-3600))
        XCTAssertEqual(f.end, noon.addingTimeInterval(1800 + 3600))
        XCTAssertEqual(f.label, "LSZQ → LFGA")
    }

    func testAnUndatedFlightStaysTheSameFlightForAMinute() {
        let plan = FlightPlan(name: "T", waypoints: [FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.39, longitude: 7.03))],
                              aircraftTypeId: "wt9", aircraftRegistration: "F-HVXA", aircraftModelName: "WT9")
        XCTAssertEqual(NotamFlight.make(plan: plan, departure: nil, now: noon.addingTimeInterval(1)),
                       NotamFlight.make(plan: plan, departure: nil, now: noon.addingTimeInterval(40)))
    }

    // MARK: New since the tick (q4 A)

    func testOnlyWhatArrivedAfterTheTickIsNew() {
        let tick = noon
        let along = NotamSorter.sort([onRoute("1"), onRoute("2"), onRoute("3")], for: flight()).along
        let seen = ["1": Date.distantPast, "2": tick.addingTimeInterval(-60), "3": tick.addingTimeInterval(60)]
        XCTAssertEqual(NotamSorter.newSince(tick, along: along, firstSeen: seen), 1)
        XCTAssertEqual(NotamSorter.newSince(tick, along: [], firstSeen: seen), 0, "only along the flight")
    }
}
