import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// The map and the Cockpit must render well inside the main-thread stack of an iPhone or iPad (1 MB).
///
/// Built as one inline value, the map took more than all of it (about 1.5 MB in a Debug build and a
/// little over 1 MB in Release, with Xcode 27 on iOS 27), and the app crashed on the stack guard
/// (EXC_BAD_ACCESS, code=2) whenever a map appeared (6.0.1, see `SeparateView`). The simulator gives
/// its main thread 8 MB, so the crash never shows there: these tests measure the stack a first render
/// uses instead (in the Debug build the tests run, the heavier of the two), and fail past half the
/// device's, which leaves room for the frames above the render and for the screens to grow.
@MainActor
final class ViewStackBudgetTests: XCTestCase {

    /// An iPhone's or iPad's main thread.
    private static let deviceMainThreadStack = 1 << 20
    private static let budget = deviceMainThreadStack / 2

    /// Plan › Map, as `GroundView` embeds it: the map, its controls and the bottom panel, on an iPad in
    /// portrait. This is the render that overflowed.
    func testPlanMapRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        let used = StackProbe.bytesUsed {
            render(NavigationMapView(isPresented: .constant(true), showsCloseButton: false, chrome: .plan,
                                     onShowRoutes: {}),
                   services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "Plan › Map used \(used / 1_024) KB of stack")
    }

    /// Plan › Map with the aerodrome procedures on (6.2.0): their follower on the map's body, and the
    /// content passed to the representable.
    func testPlanMapWithTheAerodromeProceduresRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        services.appState.settings.showVFRCircuitsOnMap = true
        services.appState.settings.showVFRRoutesOnMap = true
        services.appState.settings.showNonPoweredCircuitsOnMap = true
        let used = StackProbe.bytesUsed {
            render(NavigationMapView(isPresented: .constant(true), showsCloseButton: false, chrome: .plan,
                                     onShowRoutes: {}),
                   services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "Plan › Map with the procedures used \(used / 1_024) KB of stack")
    }

    /// The same map in landscape: the side column instead of the bottom panel.
    func testLandscapeMapRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        let used = StackProbe.bytesUsed {
            render(NavigationMapView(isPresented: .constant(true), showsCloseButton: false, chrome: .plan),
                   services: services, size: CGSize(width: 1_180, height: 820))
        }
        XCTAssertLessThan(used, Self.budget, "the landscape map used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its checklist, on an iPad in portrait: the header, the phase bar, the pane bar
    /// and the checklist.
    func testCockpitChecklistRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        XCTAssertEqual(services.appState.currentPhase, .preflight)

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's checklist used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its map, in cruise with the checklist worked through: the Cockpit and the map in
    /// its pane, as flown.
    func testCockpitMapRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        // Without step-by-step checking a phase counts as worked through, so the Cockpit shows the map.
        startFlight(services.appState, stepByStep: false)
        services.appState.goToPhase(.cruise)
        XCTAssertEqual(services.appState.currentPhase, .cruise)

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's map used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its map on an iPad on its side (6.2): the portrait frame, wider, the act band under
    /// the map, no side column.
    func testCockpitMapOnItsSideRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: false)
        services.appState.goToPhase(.cruise)

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 1_180, height: 820))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's map on its side used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on ROUTE in cruise with a route of six waypoints (6.2): the DEST line, the legs beside
    /// the radio, Emergency under them, the act band, on an iPad in portrait and on its side, and at a
    /// phone's width.
    func testCockpitRouteRendersWithinHalfTheDeviceStack() {
        for (size, name) in [(CGSize(width: 820, height: 1_180), "iPad portrait"),
                             (CGSize(width: 1_180, height: 820), "iPad on its side"),
                             (CGSize(width: 402, height: 874), "phone width")] {
            let services = makeServices()
            startFlight(services.appState, stepByStep: false)
            services.appState.goToPhase(.cruise)
            armRoute(services.flightPlanManager, waypoints: 6)

            let used = StackProbe.bytesUsed {
                render(FlightView(initialPane: .route), services: services, size: size)
            }
            XCTAssertLessThan(used, Self.budget, "the Cockpit's ROUTE (\(name)) used \(used / 1_024) KB of stack")
        }
    }

    /// The Cockpit in cruise with a route of six waypoints, on CHECKLIST and on MAP (6.2, the read band):
    /// NEXT with its figures in the strip and NOW | NEXT under it, over each page, on an iPad in portrait
    /// and on its side, and the phone's next line and NOW line at a phone's width.
    func testCockpitInCruiseWithARouteRendersWithinHalfTheDeviceStack() {
        for pane in [CockpitPane.checklist, .map] {
            for (size, name) in [(CGSize(width: 820, height: 1_180), "iPad portrait"),
                                 (CGSize(width: 1_180, height: 820), "iPad on its side"),
                                 (CGSize(width: 402, height: 874), "phone width")] {
                let services = makeServices()
                startFlight(services.appState, stepByStep: false)
                services.appState.goToPhase(.cruise)
                armRoute(services.flightPlanManager, waypoints: 6)

                let used = StackProbe.bytesUsed {
                    render(FlightView(initialPane: pane), services: services, size: size)
                }
                XCTAssertLessThan(used, Self.budget, "the Cockpit in cruise with a route, \(pane), \(name), used \(used / 1_024) KB of stack")
            }
        }
    }

    /// The Cockpit on its checklist in cruise with FREDA counting in the act band's first slot (6.2):
    /// the page the pilot picked over the map the flight shows.
    func testCockpitChecklistWithFredaCountingRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.currentPhase = .cruise
        services.appState.markLastItemComplete(learningMode: services.appState.effectiveLearningMode)
        services.appState.evaluateFreda(now: Date())
        XCTAssertTrue(services.appState.freda.isRunning && !services.appState.fredaDue, "FREDA counting")

        let used = StackProbe.bytesUsed {
            render(FlightView(initialPane: .checklist), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's checklist with FREDA counting used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its map in landing with the Memory test on: the check slot, then GO AROUND and
    /// TOUCH-AND-GO, in the act band. (6.1; the band 6.2)
    func testCockpitMapWithTheCheckSlotRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.settings.learningMode = false
        services.appState.currentPhase = .landing
        XCTAssertTrue(services.appState.isMemoryCheck(.landing), "the WT9 lands from memory")

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's map with the check slot used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its map in cruise with FREDA due: the check slot's FREDA, and the map as flown in
    /// cruise. (6.1)
    func testCockpitMapWithFredaDueRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.currentPhase = .cruise
        services.appState.markLastItemComplete(learningMode: services.appState.effectiveLearningMode)
        services.appState.evaluateFreda(now: Date().addingTimeInterval(FredaSchedule.interval + 1))
        XCTAssertTrue(services.appState.fredaDue)

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's map with FREDA due used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its checklist at line up with the Memory test on: ✓ DONE · NEXT in the thumb bar. (6.1)
    func testCockpitChecklistWithTheOneTapRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.settings.learningMode = false
        services.appState.currentPhase = .lineUp
        XCTAssertNotNil(services.appState.memoryConfirmationMovesTo, "the WT9 lines up from memory")

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's checklist with the one tap used \(used / 1_024) KB of stack")
    }

    /// The Cockpit on its map from circuit height (6.1, cues): the landing check shown in the slot, GO
    /// AROUND and TOUCH-AND-GO beside it, from the approach phase.
    func testCockpitMapFromCircuitHeightRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.settings.learningMode = false
        services.appState.currentPhase = .approach
        services.appState.noteFlightCue(FlightCueEvent(kind: .leg, time: Date().addingTimeInterval(-900), implied: false, aerodrome: nil))
        services.appState.noteFlightCue(FlightCueEvent(kind: .fired(.circuit), time: Date(), implied: false, aerodrome: nil))
        XCTAssertTrue(services.appState.landingCheckShown)

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit's map from circuit height used \(used / 1_024) KB of stack")
    }

    /// The Cockpit with the landed card up over it (6.1, M4).
    func testCockpitWithTheLandedCardRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.currentPhase = .landing
        services.appState.presentLandedCard(touchdown: Date().addingTimeInterval(-40), aerodrome: "LSZQ")
        XCTAssertNotNil(services.appState.landedCard)

        let used = StackProbe.bytesUsed {
            render(FlightView(), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the Cockpit with the landed card used \(used / 1_024) KB of stack")
    }

    /// A flight's page in the Flight Log with its checks (6.1, the debrief): an owed climb, a landing
    /// "not sure", FREDA missed once. (The Logbook's trend card sits in a `List` row, which `ImageRenderer`
    /// can't host: it traps tearing the list down, whatever the content.)
    func testFlightDetailWithItsChecksRendersWithinHalfTheDeviceStack() {
        let services = makeServices()
        let flight = Self.debriefedFlight(start: Date().addingTimeInterval(-7_200))

        let used = StackProbe.bytesUsed {
            render(FlightDetailView(flight: flight), services: services, size: CGSize(width: 820, height: 1_180))
        }
        XCTAssertLessThan(used, Self.budget, "the flight's page with its checks used \(used / 1_024) KB of stack")
    }

    private static func debriefedFlight(start: Date) -> Flight {
        var flight = Flight(airplane: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                            startTime: start, stopTime: start.addingTimeInterval(3_600))
        flight.checkOutcomes = ChecklistPhase.allCases.map { phase in
            CheckOutcome(phase: phase, status: phase == .climb ? .skipped : phase == .landing ? .notSure : .done)
        }
        flight.checkRecords = [
            CheckRecord(phase: .climb, kind: .owed, at: start.addingTimeInterval(900), cue: .levelOff),
            CheckRecord(phase: .climb, kind: .skipped, at: start.addingTimeInterval(1_000)),
            CheckRecord(phase: .landing, kind: .notSure, at: start.addingTimeInterval(3_300)),
        ]
        flight.fredaChecks = [.done(at: start.addingTimeInterval(1_600), due: nil),
                              .missed(FredaSchedule.Due(since: start.addingTimeInterval(2_200), waypoint: "SEGNELÉGIER"))]
        return flight
    }

    // MARK: - Helpers

    /// What the map and the Cockpit read from the environment, on test storage.
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

    /// `waypoints` from Bressaucourt southwards, armed; disarmed when the test ends.
    private func armRoute(_ manager: FlightPlanManager, waypoints count: Int) {
        var plan = manager.createFlightPlan(name: "Stack budget")
        for index in 0..<count {
            plan.waypoints.append(FlightPlanWaypoint(
                name: index == 0 ? "LSZQ" : "WP\(index)",
                coordinate: CLLocationCoordinate2D(latitude: 47.39 - Double(index) * 0.13, longitude: 7.03)))
        }
        plan.calculateRouteData()
        manager.updateFlightPlan(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.deactivateFlightPlan() }
    }

    /// A flight with the bundled WT9, cancelled when the test ends.
    private func startFlight(_ appState: AppState, stepByStep: Bool) {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = stepByStep
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
    }

    /// One render of `view` at `size`, body and layout, as the app's first frame does. `ImageRenderer`
    /// runs the same view graph without a window. It runs the views' `onAppear` too, which fetch
    /// nothing here: the test location manager has no fix, and the airport download counts as running.
    private func render<V: View>(_ view: V, services: Services, size: CGSize) {
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
        _ = renderer.uiImage
    }
}

/// Measures how much of the main thread's stack a closure uses: it paints the free stack below the
/// caller with a pattern, runs the closure, and finds the lowest word the closure overwrote. Not private:
/// the views measured on their own (`DestinationLineTests`) use it too.
enum StackProbe {
    private static let pattern: UInt64 = 0xA5C4_A5C4_A5C4_A5C4

    /// Bytes of stack `body` used below this call, to within the 16 KB left unpainted for the calls
    /// made here, and at most `depth`.
    @inline(never)
    static func bytesUsed(depth: Int = 4 << 20, _ body: () -> Void) -> Int {
        var marker = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        let thread = pthread_self()
        let stackBottom = UInt(bitPattern: pthread_get_stackaddr_np(thread)) - UInt(pthread_get_stacksize_np(thread))
        // Clear of the frames called from here (the paint, `body`'s first ones) and of the guard page.
        let top = here - 16 * 1_024
        let bottom = max(stackBottom + 64 * 1_024, here - UInt(depth))
        let words = Int((top - bottom) / 8)
        guard words > 0, let region = UnsafeMutablePointer<UInt64>(bitPattern: bottom) else {
            XCTFail("no free stack to paint below \(String(here, radix: 16))")
            return .max
        }
        region.initialize(repeating: pattern, count: words)
        body()
        var lowest = 0
        while lowest < words, region[lowest] == pattern { lowest += 1 }
        return Int(here - (bottom + UInt(lowest) * 8))
    }
}
