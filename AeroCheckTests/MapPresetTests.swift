import XCTest
@testable import AeroCheck

/// The Map sheet's presets (v6.0 · P3): one tap sets the markers for a phase of flight, and the sheet
/// shows which preset the current switches match. Airspace stays on in every one of them.
final class MapPresetTests: XCTestCase {

    func testCruiseShowsAirspaceAndReportingPointsOnly() {
        var settings = AppSettings()
        MapPreset.cruise.apply(to: &settings)
        XCTAssertTrue(settings.showOpenAIPOverlay)
        XCTAssertTrue(settings.showReportingPointsOnMap)
        XCTAssertFalse(settings.showAirportsOnMap)
        XCTAssertFalse(settings.showNavaidsOnMap)
        XCTAssertFalse(settings.showObstaclesOnMap)
    }

    func testApproachAddsAirportsAndObstacles() {
        var settings = AppSettings()
        MapPreset.approach.apply(to: &settings)
        XCTAssertTrue(settings.showOpenAIPOverlay)
        XCTAssertTrue(settings.showAirportsOnMap)
        XCTAssertTrue(settings.showObstaclesOnMap)
        XCTAssertTrue(settings.showReportingPointsOnMap)
        XCTAssertFalse(settings.showNavaidsOnMap)
    }

    func testEveryPresetKeepsAirspaceOn() {
        for preset in MapPreset.allCases {
            var settings = AppSettings()
            settings.showOpenAIPOverlay = false
            preset.apply(to: &settings)
            XCTAssertTrue(settings.showOpenAIPOverlay, "\(preset) turned airspace off")
        }
    }

    func testExactlyTheAppliedPresetMatches() {
        for preset in MapPreset.allCases {
            var settings = AppSettings()
            preset.apply(to: &settings)
            XCTAssertEqual(MapPreset.allCases.filter { $0.matches(settings) }, [preset])
        }
    }

    func testPresetsLeaveTheTrackVectorAndTilesAlone() {
        var settings = AppSettings()
        settings.showTrackVector = false
        settings.showOpenAIPTiles = true
        MapPreset.everything.apply(to: &settings)
        XCTAssertFalse(settings.showTrackVector)
        XCTAssertTrue(settings.showOpenAIPTiles)
    }

    func testAHandMadeMixMatchesNoPreset() {
        var settings = AppSettings()
        MapPreset.cruise.apply(to: &settings)
        settings.showNavaidsOnMap = true
        XCTAssertTrue(MapPreset.allCases.allSatisfy { !$0.matches(settings) })
    }
}
