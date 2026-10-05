import XCTest
@testable import AeroCheck

/// The Map sheet's presets (v6.0 · P3): one tap sets the markers for a phase of flight, and the sheet
/// shows which preset the current switches match. Airspace stays on in every one of them. And the chart
/// picked there, which the device keeps (6.2).
final class MapPresetTests: XCTestCase {

    // MARK: - The chart picked

    /// The layer survives a relaunch, on this device: after one the map came back on the ICAO chart
    /// (6.2 device check). The ICAO chart the first time.
    @MainActor
    func testTheChartPickedIsKeptAcrossLaunches() {
        let defaults = makeTestDefaults()
        let first = makeTestAppState(defaults: defaults)
        XCTAssertEqual(first.navigationMapState.selectedLayer, .icao, "the first launch")
        first.selectMapLayer(.landeskarten)
        XCTAssertEqual(first.navigationMapState.selectedLayer, .landeskarten)

        let relaunched = makeTestAppState(defaults: defaults)
        XCTAssertEqual(relaunched.navigationMapState.selectedLayer, .landeskarten)
        XCTAssertEqual(NavigationMapState.savedLayer(in: defaults), .landeskarten, "what the map's first frame reads")

        defaults.set("Topo 1:25k", forKey: NavigationMapState.layerKey)
        XCTAssertEqual(NavigationMapState.savedLayer(in: defaults), .icao, "an unknown layer: the ICAO chart")
    }

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

        // Approach with the circuits turned off by hand is Approach no more. (6.2.0)
        MapPreset.approach.apply(to: &settings)
        settings.showVFRCircuitsOnMap = false
        XCTAssertTrue(MapPreset.allCases.allSatisfy { !$0.matches(settings) })
    }

    /// The aerodrome procedures (6.2.0): Approach and Everything show the traffic circuits and the VFR
    /// routes, Cruise neither; the glider, UL and helicopter circuits are the pilot's own opt-in.
    func testApproachAndEverythingShowTheCircuitsAndRoutes() {
        for preset in MapPreset.allCases {
            var settings = AppSettings()
            preset.apply(to: &settings)
            let on = preset != .cruise
            XCTAssertEqual(settings.showVFRCircuitsOnMap, on, "\(preset)")
            XCTAssertEqual(settings.showVFRRoutesOnMap, on, "\(preset)")
            XCTAssertFalse(settings.showNonPoweredCircuitsOnMap, "\(preset) turned the opt-in on")
        }

        var settings = AppSettings()
        settings.showNonPoweredCircuitsOnMap = true
        MapPreset.cruise.apply(to: &settings)
        XCTAssertTrue(settings.showNonPoweredCircuitsOnMap, "a preset leaves the opt-in as it was")
        XCTAssertTrue(MapPreset.cruise.matches(settings), "and the preset still matches")
    }
}
