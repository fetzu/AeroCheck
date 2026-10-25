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

    // MARK: SIGMET (the author's W A, v66-22)

    /// LFRR SIGMET U01 of 24 Oct 2026 as the proxy sends it since 4.12.0 (`workers/weather/src/sigmet.ts`).
    private static let brest = #"""
{"firId":"LFRR","firName":"LFRR BREST","hazard":"TURB","qualifier":"SEV","baseFt":0,"topFt":4000,"validFrom":"2026-10-24T14:00:00.000Z","validTo":"2026-10-24T18:00:00.000Z","distanceNm":12.5,"containsPoint":false,"coords":[{"lat":48,"lon":-5},{"lat":48,"lon":-1},{"lat":50,"lon":-1}],"raw":"WSFR35 LFPW 241340\nLFRR SIGMET U01 VALID 241400/241800 LFPW-\nLFRR BREST FIR/UIR SEV TURB FCST N OF LINE N4800 W00800 - N4745\nW00430 AND NW OF LINE N4745 W00430 - N5000 W00145 SFC/FL040 MOV ENE\n40KT NC=","status":"FCST","levels":{"kind":"range","base":"SFC","top":"FL040"},"movement":{"direction":"ENE","speedKt":40,"stationary":false},"change":"NC"}
"""#

    private func sigmet(_ json: String = WeatherWordsTests.brest, _ edit: (inout [String: Any]) -> Void = { _ in }) throws
        -> AviationWeatherService.Sigmet {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        edit(&object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = AviationWeatherService.dateDecoding
        return try decoder.decode(AviationWeatherService.Sigmet.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testASigmetReadsInWordsWithItsLevelsAsWritten() throws {
        let s = try sigmet()
        XCTAssertEqual(WeatherWords.sigmetTitle(s), "Severe turbulence, forecast")
        XCTAssertEqual(WeatherWords.sigmetDetail(s, now: utc("2026-10-24T13:50:00Z")),
                       "surface to FL040 · moving ENE 40 kt, no change · 14–18 UTC · Brest FIR")
    }

    func testAnOlderProxysSigmetKeepsItsFeet() throws {
        let s = try sigmet { o in for key in ["status", "levels", "movement", "change"] { o[key] = nil } }
        XCTAssertEqual(WeatherWords.sigmetTitle(s), "Severe turbulence")
        XCTAssertEqual(WeatherWords.sigmetDetail(s, now: utc("2026-10-24T13:50:00Z")), "surface to 4000 ft · 14–18 UTC · Brest FIR")
    }

    func testTheOtherLevelsAndMovements() throws {
        func detail(_ levels: [String: Any], movement: [String: Any]? = nil, change: String? = nil) throws -> String {
            WeatherWords.sigmetDetail(try sigmet { o in
                o["levels"] = levels; o["movement"] = movement; o["change"] = change; o["validFrom"] = nil; o["validTo"] = nil
                o["firName"] = nil
            })
        }
        XCTAssertEqual(try detail(["kind": "range", "base": "FL200", "top": "FL400"], movement: ["direction": "E", "stationary": false]),
                       "FL200 to FL400 · moving E · LFRR FIR")
        XCTAssertEqual(try detail(["kind": "topAbove", "top": "FL390"], movement: ["stationary": true], change: "INTSF"),
                       "top above FL390 · stationary, intensifying · LFRR FIR")
        XCTAssertEqual(try detail(["kind": "range", "base": "3000FT", "top": "FL250"], change: "WKN"),
                       "3000 ft to FL250 · weakening · LFRR FIR")
        XCTAssertEqual(try detail(["kind": "below", "top": "FL220"]), "below FL220 · LFRR FIR")
        // A kind this build doesn't know: AWC's feet stand in.
        XCTAssertEqual(try detail(["kind": "somewhere", "top": "FL220"]), "surface to 4000 ft · LFRR FIR")
    }

    func testAValidityOffTheHourAndOnAnotherDaySaysSo() throws {
        let s = try sigmet { o in o["validFrom"] = "2026-10-24T15:02:00.000Z"; o["validTo"] = "2026-10-25T01:00:00.000Z" }
        XCTAssertTrue(WeatherWords.sigmetDetail(s, now: utc("2026-10-24T14:00:00Z")).contains("15:02–Sun 01 UTC"))
    }

    func testHailAndFreezingRainAreNeverDropped() throws {
        let tsgr = try sigmet { o in
            o["hazard"] = "TS"; o["qualifier"] = "EMBD"; o["raw"] = "LSAS SIGMET 2 VALID 241400/241800 LSZH- LSAS SWITZERLAND FIR EMBD TSGR OBS TOP FL350 STNR NC="
            o["status"] = "OBS"
        }
        XCTAssertEqual(WeatherWords.sigmetTitle(tsgr), "Embedded thunderstorms with hail, observed")
        let fzra = try sigmet { o in o["hazard"] = "ICE"; o["raw"] = "LSAS SIGMET 3 VALID 241400/241800 LSZH- LSAS SEV ICE (FZRA) FCST SFC/FL040 NC=" }
        XCTAssertEqual(WeatherWords.sigmetTitle(fzra), "Severe icing due to freezing rain, forecast")
    }

    func testCyclonesVolcanoesAndUnknownHazards() throws {
        XCTAssertEqual(WeatherWords.sigmetTitle(try sigmet { o in o["hazard"] = "TC"; o["qualifier"] = "CHAMPI"; o["status"] = nil }),
                       "Tropical cyclone CHAMPI")
        XCTAssertEqual(WeatherWords.sigmetTitle(try sigmet { o in o["hazard"] = "VA"; o["qualifier"] = "ERUPTION MT ETNA"; o["status"] = nil }),
                       "Volcanic ash (MT ETNA)")
        // Not in the words' table: AWC's codes, never a guess.
        XCTAssertEqual(WeatherWords.sigmetTitle(try sigmet { o in o["hazard"] = "MTW"; o["qualifier"] = "MOD" }), "MOD MTW, forecast")
        XCTAssertEqual(WeatherWords.sigmetTitle(try sigmet { o in o["hazard"] = "CONV"; o["qualifier"] = ""; o["status"] = nil }), "CONV")
    }

    func testEveryHazardInTheTableHasItsWords() {
        for code in WeatherWords.sigmetHazardCodes {
            let key = "wx.sigmet." + code.replacingOccurrences(of: " (", with: "_").replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: " ", with: "_")
            XCTAssertNotEqual(Bundle.main.localizedString(forKey: key, value: nil, table: nil), key, code)
        }
    }

    func testACompassPointInFrenchAndGerman() {
        XCTAssertEqual(WeatherWords.compassPoint("WSW", language: "fr"), "OSO")
        XCTAssertEqual(WeatherWords.compassPoint("ENE", language: "de"), "ONO")
        XCTAssertEqual(WeatherWords.compassPoint("ENE", language: "en"), "ENE")
    }

    // An observed area and its forecast position are two records of one SIGMET: two rows, never one id.
    func testAnObservedAreaAndItsForecastPositionAreTwoRows() throws {
        let observed = try sigmet { o in o["status"] = "OBS" }
        let forecast = try sigmet()
        XCTAssertNotEqual(observed.id, forecast.id)
    }

    // A field this build can't read leaves the SIGMET as it was, never the list without it.
    func testAMalformedSigmetFieldDropsOnlyItself() throws {
        let s = try sigmet { o in o["levels"] = "SFC/FL040"; o["movement"] = ["speedKt": "fast"] }
        XCTAssertEqual(s.hazard, "TURB")
        XCTAssertEqual(s.levels?.kind, "")
        XCTAssertNil(s.movement?.speedKt)
        XCTAssertTrue(WeatherWords.sigmetDetail(s).hasPrefix("surface to 4000 ft"))
    }
}
