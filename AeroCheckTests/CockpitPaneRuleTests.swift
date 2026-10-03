import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// Which pane the Cockpit shows by itself (v6.0 · P2): the map en route once the phase's checklist is
/// done, the checklist everywhere else and whenever one is open.
final class CockpitPaneRuleTests: XCTestCase {

    func testEnRouteTheMapOnceTheChecklistIsDone() {
        for phase in [ChecklistPhase.climb, .cruise, .descent] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true), .map, "\(phase)")
        }
    }

    func testEnRouteTheChecklistWhileItIsOpen() {
        // Entering climb shows the climb checklist; a cruise check come due brings the list back.
        for phase in [ChecklistPhase.climb, .cruise, .descent] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
    }

    /// ROUTE is the pilot's pick only: the flight never suggests it, in any phase or state. (6.2)
    func testROUTEIsNeverWhatTheFlightSuggests() {
        for phase in ChecklistPhase.allCases {
            for done in [false, true] {
                for memory in [false, true] {
                    XCTAssertNotEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: done, memoryCheck: memory),
                                      .route, "\(phase), done \(done), memory \(memory)")
                }
            }
        }
    }

    func testAPickedPageHoldsUntilTheSuggestionChanges() {
        var choice = CockpitPaneChoice()
        XCTAssertEqual(choice.pane(suggested: .checklist), .checklist)
        choice.pick(.route, suggested: .checklist)
        XCTAssertEqual(choice.pane(suggested: .checklist), .route, "ROUTE picked over the checklist")
        // The flight moves on (the checklist done, the next phase): the pick is dropped, ROUTE's too.
        choice.suggestionChanged()
        XCTAssertEqual(choice.pane(suggested: .map), .map)
        XCTAssertNil(choice.override)
    }

    func testPickingTheSuggestedPageClearsThePick() {
        var choice = CockpitPaneChoice(override: .route)
        choice.pick(.map, suggested: .map)
        XCTAssertNil(choice.override, "back on what the flight shows: nothing to drop later")
        choice.pick(.checklist, suggested: .map)
        XCTAssertEqual(choice.override, .checklist)
    }

    func testTheStripShowsWhileTheAircraftMoves() {
        let moving: [ChecklistPhase] = [.taxi, .runup, .beforeDeparture, .lineUp, .climb, .cruise, .descent,
                                        .approach, .landing, .afterLanding]
        for phase in ChecklistPhase.allCases {
            XCTAssertEqual(CockpitStripRule.showsStrip(in: phase), moving.contains(phase), "\(phase)")
        }
    }

    func testOnTheGroundAndAroundTakeOffAndLandingTheChecklist() {
        let enRoute: Set<ChecklistPhase> = [.climb, .cruise, .descent]
        for phase in ChecklistPhase.allCases where !enRoute.contains(phase) {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true), .checklist, "\(phase)")
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
    }

    // MARK: Layout (iPhone pass, I1 and I7)

    func testTheIPadStacksTheZonesInBothOrientations() {
        XCTAssertEqual(CockpitLayout.make(width: 820, height: 1110), .wide)   // iPad Air 11", portrait
        XCTAssertEqual(CockpitLayout.make(width: 1180, height: 750), .wide)   // and landscape
    }

    func testAPhoneInPortraitStacksThemNarrow() {
        XCTAssertEqual(CockpitLayout.make(width: 402, height: 790), .narrow)  // iPhone 17
        XCTAssertEqual(CockpitLayout.make(width: 375, height: 700), .narrow)  // a small phone
        XCTAssertEqual(CockpitLayout.make(width: 320, height: 1110), .narrow) // an iPad in Slide Over
    }

    func testAPhoneOnItsSideFoldsThemIntoColumns() {
        XCTAssertEqual(CockpitLayout.make(width: 750, height: 381), .columns) // iPhone 17, inside its insets
        XCTAssertEqual(CockpitLayout.make(width: 932, height: 430), .columns) // a Pro Max
    }

    func testTheDrawersLeaveThePhoneItsStripButGrowInColumns() {
        XCTAssertEqual(CockpitLayout.wide.drawerHeightFraction, 0.6)
        XCTAssertEqual(CockpitLayout.narrow.drawerHeightFraction, 0.66)
        XCTAssertGreaterThan(CockpitLayout.columns.drawerHeightFraction, CockpitLayout.narrow.drawerHeightFraction)
    }

    // MARK: Scale (iPhone pass, I6)

    func testThePhoneScaleIsPickedByDevice() {
        XCTAssertEqual(CockpitType.size(kneeboard: 24, phone: 20, scale: .kneeboard), 24)
        XCTAssertEqual(CockpitType.size(kneeboard: 24, phone: 20, scale: .phone), 20)
    }

    func testTheTestHostIsAnIPadSoItsSizesAreTheKneeboardOnes() {
        // The suite runs on an iPad simulator: the Cockpit's approved kneeboard sizes, unchanged.
        guard CockpitScale.current == .kneeboard else { return }
        XCTAssertEqual(CockpitType.row, 24)
        XCTAssertEqual(CockpitType.item, 42)
        XCTAssertEqual(CockpitType.value, 48)
        XCTAssertEqual(CockpitTarget.thumb, 104)
    }

    // MARK: Landscape margins (round 6, I-09)

    func testOnlyTheCameraSideKeepsTheSystemInset() {
        XCTAssertEqual(CameraSideRule.freeEdge(for: .landscapeRight), .trailing)  // the camera on the left
        XCTAssertEqual(CameraSideRule.freeEdge(for: .landscapeLeft), .leading)    // the camera on the right
        XCTAssertNil(CameraSideRule.freeEdge(for: .portrait))
        XCTAssertNil(CameraSideRule.freeEdge(for: .unknown))
    }

    func testTheFreeSideKeepsClearOfTheCornersButNeverWidens() {
        XCTAssertEqual(CameraSideRule.margin(systemInset: 62), 16)
        XCTAssertEqual(CameraSideRule.margin(systemInset: 0), 0)   // a phone with no inset
    }
}

/// A phone on its side: the Cockpit's column on the left (the header, the phase, CHECKLIST | MAP, the
/// strip, the thumb row) fits above the home indicator, the thumb row whole, over the map and over the
/// checklist. It was about 440 pt tall where a phone on its side has 369 to 419: the strip's values shrank
/// to about half, then, the strip holding its height (6.1.0), the thumb row ran off the screen. (6.1,
/// device check of 3 Oct)
///
/// Laid out at the phone's sizes (`CockpitScale`), so it runs on an iPhone simulator; on the iPad the
/// suite runs on, it is skipped.
@MainActor
final class CockpitColumnFitTests: XCTestCase {

    /// Current phones on their side: the room above the home indicator.
    private static let phones: [(name: String, size: CGSize)] = [
        ("iPhone 17e", CGSize(width: 844, height: 390 - 21)),
        ("iPhone 17 Pro", CGSize(width: 874, height: 402 - 21)),
        ("iPhone 17 Pro Max", CGSize(width: 956, height: 440 - 21)),
    ]

    func testTheColumnFitsBesideTheMap() throws {
        try XCTSkipUnless(CockpitScale.current == .phone, "laid out at the phone's sizes: run it on an iPhone")
        for phone in Self.phones {
            let services = makeServices()
            // Every check worked through: in cruise, the Cockpit shows the map, a route armed, the
            // check slot, MARK, Divert and More under the column.
            startFlight(services.appState, stepByStep: false)
            services.appState.goToPhase(.cruise)
            armRoute(services.flightPlanManager)
            let foot = try footPixels(render(FlightView(), services: services, size: phone.size))
            XCTAssertTrue(foot.isClear, "\(phone.name): the thumb row reaches \(foot.drawnRows) pt into the foot")
        }
    }

    func testTheColumnFitsBesideTheChecklist() throws {
        try XCTSkipUnless(CockpitScale.current == .phone, "laid out at the phone's sizes: run it on an iPhone")
        for phone in Self.phones {
            let services = makeServices()
            // The cruise list open: the checklist pane, CHECK and DEFER under the column.
            startFlight(services.appState, stepByStep: true)
            services.appState.currentPhase = .cruise
            let foot = try footPixels(render(FlightView(), services: services, size: phone.size))
            XCTAssertTrue(foot.isClear, "\(phone.name): the thumb bar reaches \(foot.drawnRows) pt into the foot")
        }
    }

    // MARK: - Helpers

    /// The column's foot, its last 2 pt across its width, against its own background (its left margin):
    /// clear when the thumb row ended above it.
    private func footPixels(_ image: CGImage) throws -> (isClear: Bool, drawnRows: Int) {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = bytes + y * perRow + x * perPixel
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        let background = pixel(4, image.height - 1)
        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let (a, b, c) = pixel(x, y)
            return abs(a - background.0) <= 3 && abs(b - background.1) <= 3 && abs(c - background.2) <= 3
        }
        // How far up from the bottom something other than the background is drawn, within the column.
        let columns = 12..<Int(FlightView.cockpitColumnWidth) - 12
        var drawnRows = 0
        for y in stride(from: image.height - 1, through: max(0, image.height - 24), by: -1) {
            guard columns.contains(where: { !isBackground($0, y) }) else { break }
            drawnRows += 1
        }
        let footIsBackground = (image.height - 2..<image.height).allSatisfy { y in columns.allSatisfy { isBackground($0, y) } }
        return (footIsBackground, drawnRows)
    }

    /// LSZQ to LSGC to LSGN, armed.
    private func armRoute(_ manager: FlightPlanManager) {
        var plan = manager.createFlightPlan(name: "Column fit")
        for (name, latitude, longitude) in [("LSZQ", 47.3923, 7.0296), ("LSGC", 47.0839, 6.7929), ("LSGN", 46.9575, 6.8647)] {
            plan.waypoints.append(FlightPlanWaypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        }
        plan.calculateRouteData()
        manager.updateFlightPlan(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.deactivateFlightPlan() }
    }

    /// What the Cockpit reads from the environment, on test storage (as `ViewStackBudgetTests`).
    private struct Services {
        let appState: AppState
        let subscriptionManager: SubscriptionManager
        let aircraftDataService: AircraftDataService
        let flightPlanManager: FlightPlanManager
        let threadManager: FlightThreadManager
        let locationManager: LocationManager
        let offlineMapManager: OfflineMapManager
        let airportDataService: AirportDataService
        let openAIPDataService: OpenAIPDataService
        let openAIPCacheManager: OpenAIPCacheManager
        let dataStatusManager: DataStatusManager
        let flightEventDetector: FlightEventDetector
        let aviationWeatherService: AviationWeatherService
        let windDataService: WindDataService
        let windsAloftService: WindsAloftService
    }

    private func makeServices() -> Services {
        let datastore = makeTestDatastore()
        let subscriptionManager = makeTestSubscriptionManager(deferLoadProducts: true)
        // The map downloads the airport database when it appears without one: not from a test.
        let airportDataService = AirportDataService()
        airportDataService.isDownloading = true
        return Services(
            appState: makeTestAppState(datastore: datastore),
            subscriptionManager: subscriptionManager,
            aircraftDataService: makeTestAircraftDataService(subscriptionManager: subscriptionManager),
            flightPlanManager: makeTestPlanManager(datastore: datastore),
            threadManager: makeTestThreadManager(datastore: datastore),
            locationManager: LocationManager(),
            offlineMapManager: OfflineMapManager(),
            airportDataService: airportDataService,
            openAIPDataService: OpenAIPDataService(),
            openAIPCacheManager: OpenAIPCacheManager(defaults: makeTestDefaults(), persistence: datastore),
            dataStatusManager: DataStatusManager(providers: [], networkMonitor: NetworkMonitor(stub: .disconnected),
                                                 userDefaults: makeTestDefaults()),
            flightEventDetector: FlightEventDetector(),
            aviationWeatherService: AviationWeatherService(),
            windDataService: WindDataService(),
            windsAloftService: WindsAloftService()
        )
    }

    /// A flight with the bundled WT9, cancelled when the test ends.
    private func startFlight(_ appState: AppState, stepByStep: Bool) {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = stepByStep
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
    }

    /// `view` at `size`, one point a pixel, without a safe area: what is above the home indicator.
    private func render<V: View>(_ view: V, services: Services, size: CGSize) throws -> CGImage {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(services.appState)
            .environment(\.cockpitTheme, CockpitTheme.resolve(.day))
            .environmentObject(services.locationManager)
            .environmentObject(services.offlineMapManager)
            .environmentObject(services.flightPlanManager)
            .environmentObject(services.airportDataService)
            .environmentObject(services.aircraftDataService)
            .environmentObject(services.openAIPCacheManager)
            .environmentObject(services.openAIPDataService)
            .environmentObject(services.dataStatusManager)
            .environmentObject(services.flightEventDetector)
            .environmentObject(services.aviationWeatherService)
            .environmentObject(services.threadManager)
            .environmentObject(services.windDataService)
            .environmentObject(services.windsAloftService)
            .environmentObject(services.subscriptionManager)
            .environmentObject(CompanionConnectivityManager.shared)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }
}
