import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// The Cockpit's ROUTE page (6.2): the DEST line, then LEGS | RADIO in one scroll (side by side on the
/// iPad, one above the other on a phone), Emergency pinned under the scroll, whole, lined up with RADIO.
/// A leg's row opens MAP on that leg, with "Back to aircraft" and the leg's DIRECT or RESUME LEG. And the
/// radio, which follows the flight on every page: until 6.2 NOW and NEXT were recomputed only when the
/// map's region moved, so on CHECKLIST they never changed.
@MainActor
final class CockpitRoutePageTests: XCTestCase {

    // MARK: - Layout

    func testOnTheIPadTheLegsSitBesideTheRadioInBothOrientations() throws {
        for size in [CGSize(width: 820, height: 700), CGSize(width: 1_180, height: 380)] {
            let parts = try layOut(waypoints: 6, size: size)
            let legs = try XCTUnwrap(parts[.legs]), radio = try XCTUnwrap(parts[.radio])
            XCTAssertLessThan(legs.maxX, radio.minX, "LEGS left of RADIO at \(size.width)")
            XCTAssertEqual(radio.minY, legs.minY, "side by side at \(size.width)")
            XCTAssertEqual(radio.width, LegsPanelColumns.frequencyWidth)
            XCTAssertEqual(radio.maxX, size.width - 16, "RADIO at the right, inside the page's margin")
        }
    }

    func testOnAPhoneTheRadioIsUnderTheLegs() throws {
        let parts = try layOut(waypoints: 6, size: CGSize(width: 402, height: 520), layout: .narrow)
        let legs = try XCTUnwrap(parts[.legs]), radio = try XCTUnwrap(parts[.radio])
        XCTAssertGreaterThanOrEqual(radio.minY, legs.maxY, "RADIO under LEGS")
        XCTAssertEqual(legs.minX, 16)
        XCTAssertEqual(radio.minX, 16)
        XCTAssertEqual(radio.width, 402 - 32, "the page's width")
    }

    func testEmergencyIsPinnedWholeUnderTheOneScroll() throws {
        // Twenty legs: more than the page, so the legs and the radio scroll, together.
        let size = CGSize(width: 820, height: 600)
        let parts = try layOut(waypoints: 20, size: size)
        let scroll = try XCTUnwrap(parts[.scroll]), emergency = try XCTUnwrap(parts[.emergency])
        let legs = try XCTUnwrap(parts[.legs]), radio = try XCTUnwrap(parts[.radio])
        XCTAssertGreaterThan(legs.height, scroll.height, "the legs run past the page: they scroll")
        XCTAssertGreaterThanOrEqual(emergency.minY, scroll.maxY, "Emergency is outside the scroll, under it")
        XCTAssertLessThanOrEqual(emergency.maxY, size.height, "whole, on the page")
        XCTAssertGreaterThan(emergency.height, 40, "a frequency row, not squeezed")
        XCTAssertGreaterThanOrEqual(legs.minY, scroll.minY)
        XCTAssertGreaterThanOrEqual(radio.minY, scroll.minY, "the radio in the same scroll as the legs")
    }

    func testEmergencyLinesUpWithTheRadioColumn() throws {
        let iPad = try layOut(waypoints: 6, size: CGSize(width: 820, height: 700))
        XCTAssertEqual(iPad[.emergency]?.minX, iPad[.radio]?.minX, "under RADIO, beside the legs")
        XCTAssertEqual(iPad[.emergency]?.width, iPad[.radio]?.width)
        let phone = try layOut(waypoints: 6, size: CGSize(width: 402, height: 520), layout: .narrow)
        XCTAssertEqual(phone[.emergency]?.minX, 16, "a phone: the page's width")
        XCTAssertEqual(phone[.emergency]?.width, 402 - 32)
    }

    /// The iPad's one-line DEST needs about 520 pt: in a window narrower than that (Slide Over) it runs
    /// past its edge, and the page keeps its width. It made the page wider than the window, centred, every
    /// column moved off the margin.
    func testTheDestLineNeverWidensThePage() throws {
        let parts = try layOut(waypoints: 6, size: CGSize(width: 402, height: 520), layout: .narrow, scale: .kneeboard)
        XCTAssertEqual(parts[.legs]?.minX, 16)
        XCTAssertEqual(parts[.emergency]?.maxX, 402 - 16)
    }

    /// No soft scroll edge on ROUTE's scroll: under the iPad's landscape capture hook the top of it, the
    /// leg being flown and NOW / NEXT, came out blurred and dimmed (iOS 26's scroll edge effect). The
    /// effect is drawn by the system, not by the view graph `ImageRenderer` renders, so the test pins
    /// the modifier in the scroll's type instead of reading pixels.
    func testROUTEsScrollHasNoSoftEdge() {
        let scroll = RouteLegsAndRadio(layout: .wide, hasLegs: true, onShowLeg: { _ in })
        XCTAssertTrue(String(reflecting: type(of: scroll.body)).contains("SharpScrollEdges"),
                      "\(type(of: scroll.body))")
    }

    func testWithoutARouteTheRadioTakesThePage() throws {
        let parts = try layOut(waypoints: 0, size: CGSize(width: 820, height: 700))
        XCTAssertNil(parts[.legs])
        XCTAssertEqual(parts[.radio]?.minX, 16)
        XCTAssertEqual(parts[.radio]?.width, 820 - 32)
        XCTAssertEqual(parts[.emergency]?.width, 820 - 32)
    }

    // MARK: - The radio on every page

    func testTheRadioFollowsTheFlightOnTheChecklistPage() throws {
        let services = makeServices()
        startFlight(services.appState)
        // No airport database in a test: NOW and NEXT in the plan's order, from the frequencies typed.
        var plan = makePlan(services.flightPlanManager, waypoints: 3)
        plan.waypoints[0].frequency = "120.100"
        plan.waypoints[1].frequency = "119.175"
        services.flightPlanManager.updateFlightPlan(plan)
        services.flightPlanManager.activateFlightPlan(plan)
        // A fix in the Jura: the area's Info joins the list.
        services.locationManager.currentLocation = CLLocation(latitude: 47.05, longitude: 7.15)
        let radio = CockpitRadio()
        radio.publish = { _ in }

        _ = render(FlightView(initialPane: .checklist, radio: radio), services: services,
                   size: CGSize(width: 820, height: 1_180))

        XCTAssertGreaterThanOrEqual(radio.computations, 1, "computed with no map on screen")
        XCTAssertEqual(radio.now?.freq, "120.100")
        XCTAssertEqual(radio.next?.freq, "119.175")
        XCTAssertTrue(radio.stations.contains { $0.station == "Geneva Info" }, "\(radio.stations.map(\.station))")
        XCTAssertEqual(radio.emergency.map(\.freq), ["121.500"])
    }

    // MARK: - A leg on MAP

    func testALegIsFramedFromTheWaypointBeforeIt() {
        XCTAssertEqual(LegFraming.waypoints(leg: 3, count: 6), [2, 3])
        XCTAssertEqual(LegFraming.waypoints(leg: 5, count: 6), [4, 5], "the last leg")
        XCTAssertEqual(LegFraming.waypoints(leg: 0, count: 6), [0, 1], "the departure's row: the first leg")
        XCTAssertEqual(LegFraming.waypoints(leg: 0, count: 1), [0])
        XCTAssertEqual(LegFraming.waypoints(leg: 6, count: 6), [], "past the route")
    }

    func testTheLegsActionIsDirectAheadAndResumeLegBehind() {
        XCTAssertEqual(LegFraming.action(leg: 4, nextIndex: 2, diverting: false), .direct)
        XCTAssertEqual(LegFraming.action(leg: 1, nextIndex: 2, diverting: false), .resumeLeg)
        XCTAssertEqual(LegFraming.action(leg: 2, nextIndex: 2, diverting: false), .none, "the leg being flown")
        XCTAssertEqual(LegFraming.action(leg: 2, nextIndex: 2, diverting: true), .direct, "rejoining from a diversion")
        XCTAssertEqual(LegFraming.action(leg: 5, nextIndex: 6, diverting: false), .resumeLeg, "the route flown")
    }

    func testTheLegClearsTheChromeButStaysOnAShortChart() {
        let tall = LegFraming.edgePadding(chartSize: CGSize(width: 820, height: 640), topChrome: 190, bottomChrome: 150)
        XCTAssertEqual(tall.top, 206)
        XCTAssertEqual(tall.bottom, 166)
        XCTAssertEqual(tall.left, 40)
        // The iPad on its side: a chart about 280 pt tall keeps a fifth of it for the leg.
        let short = LegFraming.edgePadding(chartSize: CGSize(width: 1_180, height: 280), topChrome: 190, bottomChrome: 150)
        XCTAssertEqual(short.top, 280 * 0.45, accuracy: 0.001)
        XCTAssertEqual(short.bottom, 280 * 0.35, accuracy: 0.001)
        XCTAssertEqual(280 - short.top - short.bottom, 56, accuracy: 0.001)
    }

    func testALegTappedIsShownUntilBackToAircraft() {
        let nav = CockpitNavState()
        XCTAssertNil(nav.framedLeg)
        nav.showLeg(3)
        XCTAssertEqual(nav.framedLeg, 3)
        nav.endLegFraming()
        XCTAssertNil(nav.framedLeg)
    }

    func testALegsTimeIsTheTimerOnTheLegFlownAndATOToATOBehind() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var plan = FlightPlan(name: "Times", waypoints: (0..<4).map {
            FlightPlanWaypoint(name: "W\($0)", coordinate: .init(latitude: 47 + Double($0) * 0.1, longitude: 7))
        })
        plan.waypoints[0].actualTimeOver = start
        plan.waypoints[1].actualTimeOver = start.addingTimeInterval(600)
        plan.currentWaypointIndex = 2
        XCTAssertEqual(RouteLegRow.actualTime(plan: plan, index: 1, legTimer: 90), 600, "ATO to ATO")
        XCTAssertEqual(RouteLegRow.actualTime(plan: plan, index: 2, legTimer: 90), 90, "the leg timer")
        XCTAssertNil(RouteLegRow.actualTime(plan: plan, index: 2, legTimer: 0), "the timer not started")
        XCTAssertNil(RouteLegRow.actualTime(plan: plan, index: 3, legTimer: 90), "a leg ahead")
        XCTAssertNil(RouteLegRow.actualTime(plan: plan, index: 0, legTimer: 90), "the departure has no leg")
    }

    // MARK: - Helpers

    /// ROUTE at `size` with an active plan of `waypoints` (none: no plan), and where each part landed.
    private func layOut(waypoints: Int, size: CGSize, layout: CockpitLayout = .wide,
                        scale: CockpitScale? = nil) throws -> [RoutePagePart: CGRect] {
        let scale = scale ?? (layout == .wide ? .kneeboard : .phone)
        let services = makeServices()
        startFlight(services.appState)
        if waypoints > 0 {
            let plan = makePlan(services.flightPlanManager, waypoints: waypoints)
            services.flightPlanManager.activateFlightPlan(plan)
        }
        final class Box { var parts: [RoutePagePart: CGRect] = [:] }
        let box = Box()
        let page = CockpitRoutePage(layout: layout, onShowLeg: { _ in }, scale: scale, onLayout: { box.parts[$0] = $1 })
        _ = render(page, services: services, size: size)
        XCTAssertFalse(box.parts.isEmpty, "the page reported its parts")
        return box.parts
    }

    /// `count` waypoints from Bressaucourt southwards, 8 NM apart, saved; deactivated when the test ends.
    @discardableResult
    private func makePlan(_ manager: FlightPlanManager, waypoints count: Int) -> FlightPlan {
        var plan = manager.createFlightPlan(name: "Route page")
        for index in 0..<count {
            let name = index == 0 ? "LSZQ" : index == count - 1 ? "LSGN" : "WP\(index)"
            plan.waypoints.append(FlightPlanWaypoint(
                name: name, coordinate: CLLocationCoordinate2D(latitude: 47.39 - Double(index) * 0.13, longitude: 7.03)))
        }
        plan.calculateRouteData()
        manager.updateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.deactivateFlightPlan() }
        return plan
    }

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

    /// What ROUTE and the Cockpit read from the environment, on test storage (as `ViewStackBudgetTests`).
    private func makeServices() -> Services {
        let datastore = makeTestDatastore()
        let subscriptionManager = makeTestSubscriptionManager(deferLoadProducts: true)
        // No airport database (the simulator app's own may be there), and none downloaded by the radio.
        let airportDataService = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
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
    private func startFlight(_ appState: AppState) {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
    }

    /// One render of `view` at `size`, with the Cockpit's environment (its radio and its nav state too).
    @discardableResult
    private func render<V: View>(_ view: V, services: Services, size: CGSize) -> UIImage? {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(services.appState)
            .environment(CockpitNavState())
            .environment(radio)
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
        return renderer.uiImage
    }
}
