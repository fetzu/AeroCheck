import XCTest
@testable import AeroCheck

/// The weather block's words (6.6.0): the proxy's decoded fields (`workers/weather/src/decode.ts`), read leniently, put
/// in words in English, the test host's language. The JSON below is what the server's decoder writes for three real-shaped
/// reports, so a change of shape on either side shows here.
final class WeatherWordsTests: XCTestCase {

    private static let sample = #"""
{"metar":{"auto":false,"corrected":false,"rvr":[],"temperatureC":15,"dewpointC":7,"qnh":{"value":1021,"unit":"hPa"},"recentWeather":[{"intensity":null,"descriptor":null,"phenomena":["RA"]}],"windShear":[],"nosig":false,"trends":[{"change":"TEMPO","from":null,"until":null,"at":null,"visibility":{"value":3000,"unit":"m","qualifier":null,"ndv":false},"weather":[{"intensity":null,"descriptor":"TS","phenomena":["RA"]}]}],"extras":[],"remarks":false,"wind":{"dirDeg":220,"variable":false,"calm":false,"speed":6,"gust":16,"speedAbove":false,"unit":"kt","varFromDeg":190,"varToDeg":250},"visibility":{"value":4000,"unit":"m","qualifier":null,"ndv":false},"minimumVisibility":{"value":1500,"direction":"SW"},"weather":[{"intensity":"light","descriptor":"SH","phenomena":["RA"]},{"intensity":null,"descriptor":null,"phenomena":["BR"]}],"clouds":[{"cover":"SCT","baseFt":800,"type":null},{"cover":"BKN","baseFt":2500,"type":"CB"}]},"metarUS":{"auto":true,"corrected":false,"rvr":[{"runway":"23","value":4500,"qualifier":null,"maxValue":6000,"maxQualifier":"moreThan","unit":"ft","trend":null}],"temperatureC":5,"dewpointC":5,"qnh":{"value":30.45,"unit":"inHg"},"recentWeather":[],"windShear":[],"nosig":false,"trends":[],"extras":[],"remarks":true,"wind":{"dirDeg":120,"variable":false,"calm":false,"speed":3,"gust":null,"speedAbove":false,"unit":"kt","varFromDeg":null,"varToDeg":null},"visibility":{"value":1.5,"unit":"SM","qualifier":null,"ndv":false},"weather":[{"intensity":null,"descriptor":null,"phenomena":["FG"]}],"clouds":[{"cover":"VV","baseFt":300,"type":null}]},"taf":{"amended":false,"corrected":false,"validFrom":"2026-10-24T12:00:00.000Z","validTo":"2026-10-25T18:00:00.000Z","periods":[{"change":"base","probability":null,"tempo":false,"from":"2026-10-24T12:00:00.000Z","to":"2026-10-24T22:00:00.000Z","wind":{"dirDeg":240,"variable":false,"calm":false,"speed":8,"gust":null,"speedAbove":false,"unit":"kt","varFromDeg":null,"varToDeg":null},"visibility":{"value":10000,"unit":"m","qualifier":"atLeast","ndv":false},"clouds":[{"cover":"FEW","baseFt":4000,"type":null}]},{"change":"PROB","probability":30,"tempo":true,"from":"2026-10-24T14:00:00.000Z","to":"2026-10-24T18:00:00.000Z","visibility":{"value":4000,"unit":"m","qualifier":null,"ndv":false},"weather":[{"intensity":null,"descriptor":"SH","phenomena":["RA"]}],"clouds":[{"cover":"BKN","baseFt":2500,"type":"TCU"}]},{"change":"FM","probability":null,"tempo":false,"from":"2026-10-24T22:00:00.000Z","to":"2026-10-25T18:00:00.000Z","wind":{"dirDeg":null,"variable":true,"calm":false,"speed":3,"gust":null,"speedAbove":false,"unit":"kt","varFromDeg":null,"varToDeg":null},"visibility":{"value":6000,"unit":"m","qualifier":null,"ndv":false},"clouds":[{"cover":"BKN","baseFt":1500,"type":null}]},{"change":"BECMG","probability":null,"tempo":false,"from":"2026-10-25T03:00:00.000Z","to":"2026-10-25T05:00:00.000Z","cavok":true}],"temperatures":[],"extras":[],"remarks":false}}
"""#

    private struct Sample: Decodable { let metar: DecodedMetar; let metarUS: DecodedMetar; let taf: DecodedTaf }

    private func decoded() throws -> Sample {
        try JSONDecoder().decode(Sample.self, from: Data(Self.sample.utf8))
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testAMetarReadsAsOneLineInItsOwnUnits() throws {
        let words = try XCTUnwrap(WeatherWords.metar(decoded().metar))
        XCTAssertEqual(words, "Wind 220° 6 kt, gusts 16 kt, 190–250° · 4000 m (min. 1500 m SW) · light rain showers · mist"
                       + " · scattered at 800 ft, broken at 2500 ft (CB) · 15 °C, dew point 7 · QNH 1021 · recent rain"
                       + ". Temporarily: 3000 m · thunderstorm with rain")
    }

    func testAnAmericanMetarKeepsItsStatuteMilesAndInches() throws {
        let words = try XCTUnwrap(WeatherWords.metar(decoded().metarUS))
        XCTAssertEqual(words, "Wind 120° 3 kt · 1 1/2 SM · fog · vertical visibility 300 ft · RVR 23: 4500 ft–more than"
                       + " 6000 ft · 5 °C, dew point 5 · altimeter 30.45 inHg")
    }

    func testATafKeepsThePeriodsThatMatterForTheFlight() throws {
        let lines = WeatherWords.taf(try decoded().taf, now: utc("2026-10-24T12:30:00Z"), departure: utc("2026-10-24T13:30:00Z"))
        XCTAssertEqual(lines, [
            "Until 22 UTC: Wind 240° 8 kt · 10 km or more · few clouds at 4000 ft",
            "14–18 UTC, 30 % chance at times: 4000 m · rain showers · broken at 2500 ft (TCU)",
        ])
    }

    func testALaterDepartureReachesTheLaterPeriods() throws {
        let lines = WeatherWords.taf(try decoded().taf, now: utc("2026-10-24T12:30:00Z"), departure: utc("2026-10-24T21:00:00Z"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last, "From 22 UTC: Wind variable 3 kt · 6 km · broken at 1500 ft")
    }

    func testCalmAndCavok() {
        var d = DecodedMetar()
        d.conditions.wind = DecodedWind(dirDeg: 0, calm: true, speed: 0)
        d.conditions.cavok = true
        d.qnh = 1030
        XCTAssertEqual(WeatherWords.metar(d), "Calm · CAVOK · QNH 1030")
    }

    func testAWeatherGroupWithoutWordsReadsAsItsCode() {
        XCTAssertEqual(WeatherWords.weather(DecodedWeatherGroup(intensity: "heavy", descriptor: "DR", phenomena: ["DU"])), "+DRDU")
    }

    func testNothingToSayShowsTheRawReport() {
        XCTAssertNil(WeatherWords.metar(DecodedMetar()))
    }

    func testAMalformedFieldDropsOnlyItself() throws {
        let json = #"{"wind":{"dirDeg":"x","speed":8,"unit":"kt"},"visibility":{"value":"far","unit":"m"},"qnh":{"value":1013}}"#
        let d = try JSONDecoder().decode(DecodedMetar.self, from: Data(json.utf8))
        XCTAssertNil(d.conditions.visibility)
        XCTAssertEqual(d.conditions.wind?.speed, 8)
        XCTAssertEqual(d.qnh, 1013)
    }

    func testAMetarWithoutDecodeStillReads() throws {
        let json = #"{"icao":"LSZH","lat":47.46,"lon":8.55,"distanceNm":0,"windVariable":false,"raw":"METAR LSZH 241020Z 24008KT 9999 FEW045 14/05 Q1022"}"#
        let metar = try JSONDecoder().decode(AviationWeatherService.Metar.self, from: Data(json.utf8))
        XCTAssertNil(metar.decoded)
        XCTAssertNotNil(metar.raw)
    }
}
