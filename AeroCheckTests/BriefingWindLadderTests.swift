import XCTest
import CoreLocation
@testable import AeroCheck

/// The rule that decides which of three differently-trustworthy winds a pilot is shown before a
/// departure or an approach. Kept pure so it fails here rather than in a cockpit.
final class BriefingWindLadderTests: XCTestCase {

    // MARK: - Builders

    private func metar(
        _ icao: String = "LSGG", distanceNm: Double = 10, elevationM: Double? = 400,
        dir: Int? = 240, variable: Bool = false, speedKt: Int? = 8, gustKt: Int? = nil
    ) -> BriefingWindLadder.MetarCandidate {
        .init(icao: icao, distanceNm: distanceNm, elevationM: elevationM,
              directionDeg: dir, isVariable: variable, speedKt: speedKt, gustKt: gustKt,
              observedAt: Date(timeIntervalSince1970: 1_785_196_800))
    }

    /// A reading `ageMinutes` old now: `select` ages it against the clock unless given a `now`.
    private func station(
        _ name: String = "Sion", distanceM: Double = 5_000, altitudeM: Double = 450,
        speedKmh: Double = 18.5, dir: Double = 270, ageMinutes: Double = 5
    ) -> WindData {
        .init(stationName: name, speedKmh: speedKmh, directionDegrees: dir,
              timestamp: Date().addingTimeInterval(-ageMinutes * 60),
              stationCoordinate: CLLocationCoordinate2D(latitude: 46.2, longitude: 7.3),
              distanceMeters: distanceM, stationAltitudeMeters: altitudeM)
    }

    private let model = BriefingWindLadder.ModelCandidate(
        directionDeg: 100, speedKt: 5, gustKt: 12, validAt: nil
    )

    // MARK: - Ladder order

    func testMetarWinsWhenUsable() {
        let wind = BriefingWindLadder.select(
            metars: [metar()], station: station(), model: model, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .metar(icao: "LSGG"))
        XCTAssertEqual(wind?.speedKt, 8)
    }

    func testFallsToStationWhenNoMetarIsUsable() {
        let wind = BriefingWindLadder.select(
            metars: [], station: station(), model: model, aircraftAltitudeM: 450
        )
        XCTAssertEqual(wind?.source, .meteoSwiss(station: "Sion"))
        XCTAssertEqual(wind?.speedKt, 10, "18.5 km/h is 10 kt")
    }

    func testFallsToModelWhenNeitherObservationIsUsable() {
        let wind = BriefingWindLadder.select(
            metars: [], station: nil, model: model, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .model)
        XCTAssertFalse(wind?.source.isObservation ?? true)
    }

    /// Returning nil rather than a placeholder is the point — a briefing with no wind is honest,
    /// a fabricated calm is not.
    func testReturnsNilRatherThanInventingCalm() {
        XCTAssertNil(BriefingWindLadder.select(
            metars: [], station: nil, model: nil, aircraftAltitudeM: 400
        ))
    }

    // MARK: - Gates

    func testDistantMetarLosesToACloseStation() {
        // The ladder is not blind precedence: a report 80 nm away is describing different air, so
        // the dense Swiss network wins.
        let wind = BriefingWindLadder.select(
            metars: [metar("LSZH", distanceNm: 80)], station: station(), model: model,
            aircraftAltitudeM: 450
        )
        XCTAssertEqual(wind?.source, .meteoSwiss(station: "Sion"))
    }

    func testMetarAtAVeryDifferentElevationIsRejected() {
        // A ridge report does not describe a valley field 5 nm away. This is the failure mode that
        // makes the Alps hard, and it applies to observations too, not just the model.
        let wind = BriefingWindLadder.select(
            metars: [metar("HIGH", distanceNm: 5, elevationM: 2_500)],
            station: nil, model: model, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .model)
    }

    func testDistantStationIsRejected() {
        let wind = BriefingWindLadder.select(
            metars: [], station: station(distanceM: 60_000), model: model, aircraftAltitudeM: 450
        )
        XCTAssertEqual(wind?.source, .model)
    }

    func testStationAtAVeryDifferentElevationIsRejected() {
        let wind = BriefingWindLadder.select(
            metars: [], station: station(altitudeM: 3_500), model: model, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .model)
    }

    func testUnknownElevationDoesNotDisqualify() {
        // A missing figure is not evidence of a mismatch. Rejecting on it would discard good
        // observations at fields with no elevation on record.
        XCTAssertTrue(BriefingWindLadder.altitudeIsPlausible(readingM: nil, aircraftM: 400))
        XCTAssertTrue(BriefingWindLadder.altitudeIsPlausible(readingM: 400, aircraftM: nil))
        let wind = BriefingWindLadder.select(
            metars: [metar(elevationM: nil)], station: nil, model: model, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .metar(icao: "LSGG"))
    }

    func testNearestUsableMetarWins() {
        let wind = BriefingWindLadder.select(
            metars: [metar("FAR", distanceNm: 40), metar("NEAR", distanceNm: 6)],
            station: nil, model: nil, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .metar(icao: "NEAR"))
    }

    /// A station reporting no wind at all is skipped, not shown as calm.
    func testMetarWithoutAWindIsSkipped() {
        let wind = BriefingWindLadder.select(
            metars: [metar("NOWIND", distanceNm: 2, speedKt: nil), metar("GOOD", distanceNm: 30)],
            station: nil, model: nil, aircraftAltitudeM: 400
        )
        XCTAssertEqual(wind?.source, .metar(icao: "GOOD"))
    }

    // MARK: - Freshness

    /// The MeteoSwiss feed is a 10-minute mean. A reading older than 20 minutes is no longer the
    /// wind at the field and must not be briefed as current: the ladder moves on to the next rung.
    func testStaleStationReadingIsNotBriefed() {
        let stale = WindData(stationName: "Sion", speedKmh: 18.5, directionDegrees: 270,
                             timestamp: Date().addingTimeInterval(-45 * 60),
                             stationCoordinate: CLLocationCoordinate2D(latitude: 46.2, longitude: 7.3),
                             distanceMeters: 5_000, stationAltitudeMeters: 450)
        let wind = BriefingWindLadder.select(metars: [], station: stale, model: model, aircraftAltitudeM: 450)
        XCTAssertEqual(wind?.source, .model)
    }

    /// With nothing else to fall back on, a stale reading leaves the briefing without a wind (shown
    /// as "not available", with the hint to check it) rather than with an old one.
    func testStaleStationReadingAloneGivesNoWind() {
        XCTAssertNil(BriefingWindLadder.select(metars: [], station: station(ageMinutes: 45), model: nil,
                                               aircraftAltitudeM: 450))
    }

    /// Twenty minutes is still usable, a minute more is not; the time is the caller's.
    func testStationAgeLimitIsTwentyMinutes() {
        let reading = station(ageMinutes: 0)
        let at20 = BriefingWindLadder.select(metars: [], station: reading, model: nil, aircraftAltitudeM: 450,
                                             now: reading.timestamp.addingTimeInterval(20 * 60))
        let at21 = BriefingWindLadder.select(metars: [], station: reading, model: nil, aircraftAltitudeM: 450,
                                             now: reading.timestamp.addingTimeInterval(21 * 60))
        XCTAssertEqual(at20?.source, .meteoSwiss(station: "Sion"))
        XCTAssertNil(at21)
    }

    /// A reading inside the window still beats the model.
    func testFreshStationStillWinsOverTheModel() {
        let wind = BriefingWindLadder.select(metars: [], station: station(ageMinutes: 12), model: model,
                                             aircraftAltitudeM: 450)
        XCTAssertEqual(wind?.source, .meteoSwiss(station: "Sion"))
    }

    // MARK: - VRB

    func testVariableCarriesNoDirection() {
        let wind = BriefingWindLadder.select(
            metars: [metar(dir: 240, variable: true)], station: nil, model: nil, aircraftAltitudeM: 400
        )
        XCTAssertNil(wind?.directionDeg, "VRB must not be given a heading, even if one arrived")
        XCTAssertTrue(wind?.isVariable ?? false)
    }

    // MARK: - Presentation: value first, provenance last

    func testDisplayPutsTheValueFirstAndProvenanceLast() {
        let wind = BriefingWind(directionDeg: 240, speedKt: 8, gustKt: nil,
                                source: .metar(icao: "LSGG"), distanceNm: 21.4, observedAt: nil)
        XCTAssertEqual(wind.value, "240° 8 kt")
        XCTAssertEqual(wind.provenance, "METAR LSGG, 21 nm")
        XCTAssertEqual(wind.display, "240° 8 kt (METAR LSGG, 21 nm)")
    }

    func testGustIsShownWithTheValue() {
        let wind = BriefingWind(directionDeg: 270, speedKt: 15, gustKt: 25,
                                source: .metar(icao: "LSZH"), distanceNm: 4, observedAt: nil)
        XCTAssertEqual(wind.value, "270° 15 kt G25")
    }

    func testVariableReadsAsVRBNotAsAHeading() {
        let wind = BriefingWind(directionDeg: nil, speedKt: 3, gustKt: nil,
                                source: .metar(icao: "LSGG"), distanceNm: 2, observedAt: nil)
        XCTAssertEqual(wind.value, "VRB 3 kt")
        XCTAssertFalse(wind.value.contains("0°"))
    }

    func testDirectionIsZeroPaddedToThreeDigits() {
        let wind = BriefingWind(directionDeg: 8, speedKt: 10, gustKt: nil,
                                source: .model, distanceNm: nil, observedAt: nil)
        XCTAssertEqual(wind.value, "008° 10 kt", "aviation convention is three digits")
    }

    func testModelIsLabelledAndCarriesNoStationDistance() {
        let wind = BriefingWind(directionDeg: 100, speedKt: 5, gustKt: nil,
                                source: .model, distanceNm: nil, observedAt: nil)
        XCTAssertEqual(wind.provenance, L10n.Briefing.windModelForecast)
        XCTAssertFalse(wind.provenance.contains("nm"), "a grid cell has no station to be far from")
        XCTAssertFalse(wind.source.isObservation)
    }

    func testStationProvenanceNamesTheStation() {
        let wind = BriefingWind(directionDeg: 270, speedKt: 10, gustKt: nil,
                                source: .meteoSwiss(station: "Sion"), distanceNm: 2.7, observedAt: nil)
        XCTAssertEqual(wind.display, "270° 10 kt (Sion, 3 nm)")
    }
}
