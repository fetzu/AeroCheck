import XCTest
import CoreLocation
@testable import AeroCheck

/// Prepare's weather card (q1, 22 Oct 2026): the route's fields with their reports as published, the nearest TAF
/// for a field without one, said once and then "(above)", and the SIGMETs along the route, where an empty list
/// says nothing unless the proxy received some. (6.5.0)
@MainActor
final class PrepareWeatherTests: XCTestCase {

    private func metar(_ icao: String, _ raw: String) -> AviationWeatherService.Metar {
        .init(icao: icao, name: nil, lat: 0, lon: 0, elevationM: nil, distanceNm: 0, windDirectionDeg: nil,
              windVariable: false, windSpeedKt: nil, windGustKt: nil, temperatureC: nil, dewpointC: nil,
              altimeterHpa: nil, flightCategory: nil, observedAt: nil, raw: raw)
    }

    private func taf(_ icao: String, _ raw: String, lat: Double? = nil, lon: Double? = nil) -> AviationWeatherService.Taf.Forecast {
        .init(icao: icao, issuedAt: nil, validFrom: nil, validTo: nil, raw: raw, lat: lat, lon: lon)
    }

    // Bressaucourt to Freiburg with Strasbourg as the alternate: neither LSZQ nor EDTF has a TAF, Basel-Mulhouse
    // is the nearest for both.
    private let lszq = PrepareWeather.Field(ident: "LSZQ", coordinate: .init(latitude: 47.3925, longitude: 7.0283), role: .departure)
    private let edtf = PrepareWeather.Field(ident: "EDTF", coordinate: .init(latitude: 48.0222, longitude: 7.8325), role: .destination)
    private let lfst = PrepareWeather.Field(ident: "LFST", coordinate: .init(latitude: 48.5383, longitude: 7.6282), role: .alternate)

    private var fetched: [String: PrepareWeather.Fetched] {
        let lfsbMetar = metar("LFSB", "LFSB 212230Z AUTO 00000KT 9999 BKN062 08/06 Q1021 NOSIG")
        let lfsbTaf = taf("LFSB", "TAF LFSB 211700Z 2118/2218 25007KT 9999 SCT040", lat: 47.59, lon: 7.5291)
        return [
            "LSZQ": .init(metars: [lfsbMetar], ownTaf: nil, nearbyTafs: [lfsbTaf]),
            "EDTF": .init(metars: [metar("EDTF", "EDTF 212220Z 21008KT 9999 SCT049 09/07 Q1018"), lfsbMetar],
                          ownTaf: nil, nearbyTafs: [lfsbTaf]),
            "LFST": .init(metars: [metar("LFST", "LFST 212230Z 20005KT CAVOK 07/04 Q1019")],
                          ownTaf: "TAF LFST 211700Z 2118/2218 20008KT CAVOK", nearbyTafs: []),
        ]
    }

    private func nm(_ a: CLLocationCoordinate2D, _ lat: Double, _ lon: Double) -> Int {
        Int((CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude)) / 1852)
            .rounded())
    }

    func testEachFieldOnceThenTheNearestTAFOnceAndAbove() {
        let weather = PrepareWeather.assemble(fields: [lszq, edtf, lfst], fetched: fetched, sigmets: nil, at: Date())
        XCTAssertEqual(weather.stations.map(\.ident), ["LSZQ", "LFSB", "EDTF", "LFST"], "the nearest right after the field that needs it")
        XCTAssertEqual(weather.stations.map(\.roles), [[.departure], [.nearest], [.destination], [.alternate]])
        let departure = weather.stations[0]
        XCTAssertNil(departure.metar)
        XCTAssertEqual(departure.nearest?.ident, "LFSB")
        XCTAssertEqual(departure.nearest?.distanceNm, nm(lszq.coordinate, 47.59, 7.5291),
                       "measured on the device from the field, not the proxy's grid")
        XCTAssertEqual(departure.nearest?.shownAbove, false)
        XCTAssertNotNil(weather.stations[1].metar, "the nearest station's METAR from the field's list")
        XCTAssertNotNil(weather.stations[1].taf)
        let destination = weather.stations[2]
        XCTAssertNotNil(destination.metar, "its own METAR")
        XCTAssertEqual(destination.nearest?.shownAbove, true, "LFSB's row is above: said once")
        XCTAssertNil(weather.stations[3].nearest, "a field with its own TAF needs none")
        // The words.
        XCTAssertEqual(PrepareWeatherReports.note(for: departure),
                       L10n.PrepareWeather.noMetarOrTaf(nearest: "LFSB", distanceNm: nm(lszq.coordinate, 47.59, 7.5291)))
        XCTAssertEqual(PrepareWeatherReports.note(for: destination),
                       "\(L10n.PrepareWeather.noTaf(nearest: "LFSB", distanceNm: nm(edtf.coordinate, 47.59, 7.5291))) \(L10n.PrepareWeather.above)")
        XCTAssertNil(PrepareWeatherReports.note(for: weather.stations[1]), "a NEAREST row says nothing of its own")
        XCTAssertNil(PrepareWeatherReports.note(for: weather.stations[3]))
    }

    /// A local flight: one field, both words. A field whose nearest TAF is another field of the route gets no row of
    /// its own for it.
    func testALocalFlightIsOneRowAndAFieldOfTheRouteIsNeverANearestRow() {
        let back = PrepareWeather.Field(ident: "LSZQ", coordinate: lszq.coordinate, role: .destination)
        let local = PrepareWeather.assemble(fields: [lszq, back], fetched: fetched, sigmets: nil, at: Date())
        XCTAssertEqual(local.stations.map(\.ident), ["LSZQ", "LFSB"])
        XCTAssertEqual(local.stations[0].roles, [.departure, .destination])

        var data = fetched
        data["LSZQ"]?.nearbyTafs = [taf("LFST", "TAF LFST 211700Z 2118/2218 20008KT CAVOK", lat: 48.5383, lon: 7.6282)]
        let toStrasbourg = PrepareWeather.Field(ident: "LFST", coordinate: lfst.coordinate, role: .destination)
        let weather = PrepareWeather.assemble(fields: [lszq, toStrasbourg], fetched: data, sigmets: nil, at: Date())
        XCTAssertEqual(weather.stations.map(\.ident), ["LSZQ", "LFST"], "LFST is the destination's row, not a NEAREST one")
    }

    /// The nearest TAF by the field's own distance, never the proxy's order (sorted from its grid point): for
    /// Bressaucourt, Grenchen (20 NM) before Basel-Mulhouse (24 NM), as the proxy listed them on 22 Oct.
    func testTheNearestTAFIsTheFieldsNearest() {
        var data = PrepareWeather.Fetched()
        data.nearbyTafs = [taf("LFSB", "TAF LFSB 220500Z", lat: 47.59, lon: 7.5291),
                           taf("LSZG", "TAF LSZG 220500Z", lat: 47.1817, lon: 7.4172),
                           taf("LSGC", "TAF LSGC 220500Z", lat: 47.0839, lon: 6.7928)]
        let weather = PrepareWeather.assemble(fields: [lszq], fetched: ["LSZQ": data], sigmets: nil, at: Date())
        XCTAssertEqual(weather.stations[0].nearest?.ident, "LSZG")
        XCTAssertEqual(weather.stations[0].nearest?.distanceNm, nm(lszq.coordinate, 47.1817, 7.4172))
        XCTAssertEqual(weather.stations.map(\.ident), ["LSZQ", "LSZG"])
    }

    func testNothingWithinReach() {
        let lonely = PrepareWeather.assemble(fields: [lszq], fetched: ["LSZQ": .init()], sigmets: nil, at: Date())
        XCTAssertEqual(PrepareWeatherReports.note(for: lonely.stations[0]), L10n.PrepareWeather.nothingWithin)
    }

    /// The report as published, its kind in front where AWC leaves it out (its METARs), never twice.
    func testAReportKeepsItsTextAndGetsItsKindOnce() {
        XCTAssertEqual(PrepareWeatherReports.labelled("LFSB 212230Z AUTO 00000KT", as: "METAR", or: ["METAR", "SPECI"]),
                       "METAR LFSB 212230Z AUTO 00000KT")
        XCTAssertEqual(PrepareWeatherReports.labelled("SPECI LFSB 212245Z 27015KT", as: "METAR", or: ["METAR", "SPECI"]),
                       "SPECI LFSB 212245Z 27015KT")
        XCTAssertEqual(PrepareWeatherReports.labelled("TAF LFSB 211700Z 2118/2218", as: "TAF", or: ["TAF"]),
                       "TAF LFSB 211700Z 2118/2218")
        XCTAssertEqual(PrepareWeatherReports.utc(Date(timeIntervalSince1970: 81_000)), "22:30 UTC")
    }

    /// The SIGMET request takes 2 to 30 points: a longer route is thinned evenly, its ends kept.
    func testALongRouteIsThinnedToThirtyPoints() {
        let route = (0..<75).map { CLLocationCoordinate2D(latitude: 46 + Double($0) * 0.01, longitude: 7) }
        let thinned = AviationWeatherService.thinned(route, to: 30)
        XCTAssertEqual(thinned.count, 30)
        XCTAssertEqual(thinned.first?.latitude, route.first?.latitude)
        XCTAssertEqual(thinned.last?.latitude, route.last?.latitude)
        XCTAssertEqual(AviationWeatherService.thinned(Array(route.prefix(5)), to: 30).count, 5)
    }

    /// The route answer's shape, as the proxy sends it: `received` is AWC's whole set.
    func testTheRouteSigmetsDecode() throws {
        let json = """
        {"received": 163, "hazards": [{"firId": "LSAS", "firName": "SWITZERLAND", "hazard": "TURB", "qualifier": "SEV",
          "baseFt": 0, "topFt": 15000, "validFrom": "2026-10-22T06:00:00Z", "validTo": "2026-10-22T10:00:00Z",
          "distanceNm": 0, "containsPoint": true, "coords": [{"lat": 46.5, "lon": 7.0}], "raw": "LSAS SIGMET 1"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sigmets = try decoder.decode(AviationWeatherService.RouteSigmets.self, from: Data(json.utf8))
        XCTAssertEqual(sigmets.received, 163)
        XCTAssertEqual(sigmets.hazards.map(\.firId), ["LSAS"])
        XCTAssertFalse(L10n.PrepareWeather.noSigmetAlongRoute(163).isEmpty)
    }

    // MARK: - Fetching (the author's device check, 23 Oct 2026)

    /// A stand-in for the network: each call takes the next outcome, after `delay`, whatever its caller's cancellation.
    private final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [PrepareWeatherService.Outcome]
        private(set) var calls: [Bool] = []
        let delay: UInt64
        init(_ outcomes: [PrepareWeatherService.Outcome], delayMs: UInt64 = 0) {
            self.outcomes = outcomes
            delay = delayMs * 1_000_000
        }
        func next(fresh: Bool) async -> PrepareWeatherService.Outcome {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            lock.lock(); defer { lock.unlock() }
            calls.append(fresh)
            return outcomes.isEmpty ? .init() : outcomes.removeFirst()
        }
    }

    private func answered() -> PrepareWeatherService.Outcome {
        var outcome = PrepareWeatherService.Outcome()
        outcome.fetched = fetched
        outcome.anything = true
        return outcome
    }

    private func service(_ stub: Stub) -> PrepareWeatherService {
        PrepareWeatherService(fetcher: { _, _, fresh in await stub.next(fresh: fresh) })
    }

    /// The card's task is cancelled when the page redraws or closes (a flight just created does both): the fetch goes on
    /// in the service's own task and fills the card, where it used to say "could not be fetched".
    func testACancelledCardStillGetsItsWeather() async {
        let stub = Stub([answered()], delayMs: 50)
        let weather = service(stub)
        let id = UUID()
        let card = Task { await weather.load(threadId: id, fields: [lszq, edtf], route: []) }
        card.cancel()
        await card.value
        guard case .loaded(let loaded)? = weather.state(for: id) else { return XCTFail("\(String(describing: weather.state(for: id)))") }
        XCTAssertEqual(loaded.stations.first?.ident, "LSZQ")
        // The same fields again while one is loading or loaded: no second fetch.
        await weather.load(threadId: id, fields: [lszq, edtf], route: [])
        XCTAssertEqual(stub.calls.count, 1)
    }

    /// The refresh asks past the device's cache; when nothing answers, the last reports stay, said so beside them
    /// (v65-18: in airplane mode the cache answered and the card looked refreshed).
    func testAFailedRefreshKeepsTheReportsAndSaysSo() async {
        let stub = Stub([answered(), .init()])
        let weather = service(stub)
        let id = UUID()
        await weather.load(threadId: id, fields: [lszq, edtf], route: [])
        await weather.load(threadId: id, fields: [lszq, edtf], route: [], force: true)
        XCTAssertEqual(stub.calls, [false, true], "the refresh, past the cache")
        guard case .loaded? = weather.state(for: id) else { return XCTFail("the reports should stay") }
        XCTAssertTrue(weather.refreshFailed.contains(id))
        XCTAssertFalse(L10n.PrepareWeather.refreshFailed("14:46 UTC").isEmpty)
        // Nothing ever: "could not be fetched".
        let other = UUID()
        await weather.load(threadId: other, fields: [lszq], route: [])
        XCTAssertEqual(weather.state(for: other), .failed)
        XCTAssertFalse(weather.refreshFailed.contains(other))
    }

    /// The route changed while its weather was loading: the newer fetch wins, the older one's answer is dropped.
    func testAnOlderFetchComingBackLateIsDropped() async {
        let stub = Stub([answered(), answered()], delayMs: 30)
        let weather = service(stub)
        let id = UUID()
        async let first: Void = weather.load(threadId: id, fields: [lszq], route: [])
        async let second: Void = weather.load(threadId: id, fields: [lszq, edtf], route: [])
        _ = await (first, second)
        guard case .loaded(let loaded)? = weather.state(for: id) else { return XCTFail() }
        XCTAssertTrue(loaded.stations.contains { $0.ident == "EDTF" }, "the second route's fields")
    }
}
