import XCTest
@testable import AeroCheck

/// The US traffic patterns from the FAA's NASR (the author's q6, 22 Oct 2026): the side at each runway end and the
/// pattern altitude on the approach view, the FAA's remark as written in the approach briefing, never a shape and
/// never a figure read from a remark. (6.5.0)
@MainActor
final class TrafficPatternTests: XCTestCase {

    /// As the server writes it (sandbox, cycle 2610), with an end this build can't read.
    private let sample = """
    {"v": 1, "source": "FAA NASR", "attribution": "FAA NASR 28-day subscription (public domain)", "cycle": "2610",
     "aerodromes": {
      "KPAO": {"lid": "PAO", "elev": 7, "tpaRemark": "TPA 1000 FT W & 800 FT E.", "runways": ["13/31"],
               "ends": [{"rwy": "13", "pattern": "L", "pos": [-122.11766, 37.46375], "trueBrg": 142.0},
                        {"rwy": "31", "pattern": "R", "pos": [-122.11244, 37.45849], "trueBrg": 322.0},
                        {"rwy": "H1", "pattern": "X"}]},
      "KSQL": {"lid": "SQL", "elev": 6, "tpa": {"agl": 800, "msl": 806}, "runways": ["12/30"],
               "ends": [{"rwy": "12", "pattern": "L"}, {"rwy": "30", "pattern": "R"}]},
      "1N7": {"elev": 372, "ends": [{"rwy": "07", "pattern": "L"}, {"rwy": "25", "pattern": "L"}]},
      "BAD": "not an object"
     }}
    """

    private func patterns() throws -> NASRPatterns {
        try JSONDecoder().decode(NASRPatterns.self, from: Data(sample.utf8))
    }

    func testTheFileDecodesLeniently() throws {
        let file = try patterns()
        XCTAssertEqual(file.cycle, "2610")
        XCTAssertEqual(Set(file.aerodromes.keys), ["KPAO", "KSQL", "1N7"], "an entry that isn't an object is left out")
        let paloAlto = try XCTUnwrap(file.aerodrome("kpao"))
        XCTAssertEqual(paloAlto.ends.map(\.rwy), ["13", "31"], "an end with an unknown side is left out")
        XCTAssertEqual(paloAlto.side(of: "31"), .right)
        XCTAssertEqual(paloAlto.side(of: "13"), .left)
        XCTAssertNil(paloAlto.tpa)
        XCTAssertEqual(file.aerodrome("KSQL")?.tpa, .init(agl: 800, msl: 806))
    }

    /// The pattern altitude in words: the FAA's figure, else its remark to read, else the AIM's recommendation
    /// said to be one; never a figure read from a remark.
    func testTheAltitudeIsTheFAAsFigureOrItsRemark() throws {
        let file = try patterns()
        XCTAssertEqual(TrafficPatternText.altitude(try XCTUnwrap(file.aerodrome("KSQL"))), L10n.Briefing.patternAltitude(msl: 806, agl: 800))
        XCTAssertEqual(TrafficPatternText.altitude(try XCTUnwrap(file.aerodrome("KPAO"))), L10n.Briefing.patternSeeRemark,
                       "Palo Alto's TPA is only in a remark: the remark, as written")
        XCTAssertEqual(TrafficPatternText.altitude(try XCTUnwrap(file.aerodrome("1N7"))), L10n.Briefing.patternRecommended(1_000))
    }

    /// On the approach view: "30 RIGHT" and "12 LEFT" at the ends of the centreline, "TPA 806 ft" by the field; no
    /// direction arrows, for there is no circuit to put them on.
    func testTheApproachViewSaysTheSideAtEachEndAndTheAltitude() throws {
        let file = try patterns()
        let reference = VFRCoordinate(latitude: 37.5119, longitude: -122.2495)
        let runway = VFRRunwayEnds(first: .init(ident: "12", threshold: .init(latitude: 37.5145, longitude: -122.2526), trueBearing: 138),
                                   second: .init(ident: "30", threshold: .init(latitude: 37.5092, longitude: -122.2465), trueBearing: 318))
        let field = VFRApproachField.make(ident: "KSQL", reference: reference, runways: [runway], circuits: [], windFrom: 300,
                                          parachuting: false, pattern: file.aerodrome("KSQL"))
        XCTAssertEqual(field.patternSides, ["12": .left, "30": .right])
        XCTAssertEqual(field.patternAltitude, 806)
        XCTAssertTrue(field.arrows.isEmpty)
        let kinds = VFRApproachAnnotation.annotations(for: field).map(\.kind)
        XCTAssertTrue(kinds.contains(.runway("30", inUse: true, pattern: .right)))
        XCTAssertTrue(kinds.contains(.runway("12", inUse: false, pattern: .left)))
        XCTAssertTrue(kinds.contains(.patternAltitude(806)))
        XCTAssertEqual(L10n.VFRMap.patternAltitude(806), "TPA 806 ft")
        // A field without NASR's data: the numbers alone, as before.
        let plain = VFRApproachField.make(ident: "LSZQ", reference: reference, runways: [runway], circuits: [], windFrom: nil,
                                          parachuting: false)
        XCTAssertEqual(VFRApproachAnnotation.annotations(for: plain).map(\.kind),
                       [.runway("12", inUse: false), .runway("30", inUse: false)])
    }

    func testTheFileArrivesOnceAskedAndIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("nasr-us.json")
        var requests = 0
        let service = NASRPatternService(cacheURL: cache, fetch: { _ in requests += 1; return Data(self.sample.utf8) })
        XCTAssertNil(service.patterns, "nothing at launch")
        await service.loadIfNeeded()
        XCTAssertEqual(service.patterns?.aerodrome("KPAO")?.side(of: "31"), .right)
        XCTAssertEqual(requests, 1)
        await service.loadIfNeeded()
        XCTAssertEqual(requests, 1, "a week before asking again")
        let again = NASRPatternService(cacheURL: cache, fetch: { _ in requests += 1; return Data() })
        await again.loadIfNeeded()
        XCTAssertEqual(again.patterns?.aerodromes.count, 3, "from the cache")
        XCTAssertEqual(requests, 1)
    }
}
