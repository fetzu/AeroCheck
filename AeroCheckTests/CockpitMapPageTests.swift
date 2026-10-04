import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// The Cockpit's MAP page since 6.2 (PR 4), and the phone's frame around it, read as VoiceOver and the UI
/// tests read them (the hosted views' accessibility elements):
/// - the Cockpit's chart is the chart and its own chrome (the stack, the status slot); the controls row,
///   CACHED, the legs toggle and the chips are Plan › Map's, which keeps every one of them;
/// - the phone draws its phase bar in the phase button, as on its side, and its header holds one height
///   in every phase; the phase list says what the bar's segments said;
/// - on its side (PR 5) the page is on the left and the column on the right, holding still.
@MainActor
final class CockpitMapPageTests: XCTestCase {

    // MARK: - The chart and its chrome

    /// Plan › Map, on an iPad with the ICAO chart cached: the labelled controls row (Map, North up | Track
    /// up, Centre, zoom), CACHED, the legs toggle. None of the Cockpit's chrome.
    func testPlanMapKeepsEveryPieceOfItsChrome() throws {
        let services = makeServices()
        services.offlineMapManager.isCacheAvailable = true
        armRoute(services.flightPlanManager)
        let seen = accessibility(NavigationMapView(isPresented: .constant(true), showsCloseButton: false, chrome: .plan,
                                                   onShowRoutes: {}),
                                 services: services, size: CGSize(width: 820, height: 1_180))
        let labels = Set(seen.map(\.label))
        let ids = Set(seen.map(\.id))
        // The phone's row: Map, the orientation as one button, Centre; no zoom, a pinch.
        let phone = CockpitScale.current == .phone
        let expected = phone ? [L10n.Nav.mapSheet, L10n.Nav.northUp, L10n.Nav.centre, L10n.Nav.cached]
            : [L10n.Nav.mapSheet, L10n.Nav.northUp, L10n.Nav.trackUp, L10n.Nav.centre, L10n.Nav.zoomIn, L10n.Nav.zoomOut,
               L10n.Nav.cached]
        for label in expected {
            XCTAssertTrue(labels.contains { $0.contains(label) }, "Plan › Map shows \(label): \(labels.sorted())")
        }
        XCTAssertTrue(ids.contains("map.legsToggle"), "the legs toggle: \(ids.sorted())")
        for id in ["map.orientation", "map.layers", "map.centre", "map.zoomIn", "map.zoomOut"] {
            XCTAssertFalse(ids.contains(id), "no \(id) on Plan › Map")
        }
        XCTAssertFalse(ids.contains { $0.hasPrefix("status.") }, "no status slot on Plan › Map")
    }

    /// The Cockpit's MAP in cruise with a route, on an iPad, no network and no cache: the stack (N↑ or TRK,
    /// layers, centre, + and −) and the slot, CHART OFFLINE here. No CACHED, no labelled row, no legs
    /// toggle, no undo toast of the old kind.
    func testTheCockpitMapIsTheChartAndItsChrome() throws {
        let services = makeServices()
        startFlight(services.appState, stepByStep: false)
        services.appState.goToPhase(.cruise)
        services.locationManager.isTracking = true          // recording, GPS good: no GPS state first
        armRoute(services.flightPlanManager)
        let seen = accessibility(FlightView(initialPane: .map), services: services, size: CGSize(width: 820, height: 1_180))
        let ids = Set(seen.map(\.id))
        let zoom = CockpitScale.current == .kneeboard
        for id in ["map.orientation", "map.layers", "map.centre", "status.chartOffline"] + (zoom ? ["map.zoomIn", "map.zoomOut"] : []) {
            XCTAssertTrue(ids.contains(id), "\(id) on the Cockpit's chart: \(ids.sorted())")
        }
        XCTAssertEqual(ids.contains("map.zoomIn"), zoom, "zoom on the iPad only")
        XCTAssertFalse(ids.contains("map.legsToggle"))
        XCTAssertFalse(ids.contains("map.scale"), "no scale until the pilot zooms (the map setting its camera is not a zoom)")
        XCTAssertFalse(seen.contains { $0.label == L10n.Nav.cached || $0.label == L10n.Nav.offline },
                       "no CACHED or OFFLINE badge (CHART OFFLINE is the slot's)")
        XCTAssertFalse(seen.contains { $0.label == L10n.Nav.trackUp && $0.id != "map.orientation" },
                       "no North up | Track up segments")
        XCTAssertEqual(seen.first { $0.id == "map.orientation" }?.value, "northUp")
        XCTAssertEqual(seen.first { $0.id == "map.centre" }?.value, "following")
    }

    /// The scale shows on a zoom of the pilot's and goes 2 s after; the camera the map sets as MAP appears
    /// (the zoom it was left at) shows none.
    func testTheScaleShowsOnAZoomAndGoes() throws {
        let zoom = ZoomHolder()
        let host = hosted(ScaleProbe(holder: zoom), size: CGSize(width: 820, height: 560))
        defer { host.close() }
        zoom.zoom = 30_000                                    // the map setting its camera, at once
        host.settle(0.3)
        XCTAssertFalse(host.ids().contains("map.scale"), "the map's own camera: no scale")
        host.settle(1.2)
        zoom.zoom = 15_000                                    // the pilot's zoom
        host.settle(0.4)
        XCTAssertTrue(host.ids().contains("map.scale"), "a zoom: the scale")
        host.settle(2.4)
        XCTAssertFalse(host.ids().contains("map.scale"), "gone 2 s after")
    }

    // MARK: - The phone's frame

    /// The phone in portrait draws the phase bar in its phase button (no segment to touch, none read out),
    /// the button opening the phase list; the iPad keeps its bar of sixteen segments. Both name the phase
    /// for the UI tests ("cockpit.phase.preflight").
    func testThePhoneDrawsItsPhaseBarInThePhaseButton() throws {
        for (size, phone) in [(CGSize(width: 390, height: 844), true), (CGSize(width: 820, height: 1_180), false)] {
            let services = makeServices()
            startFlight(services.appState, stepByStep: true)
            let seen = accessibility(FlightView(), services: services, size: size)
            let segments = seen.filter { $0.id.hasPrefix("phaseBar.") }
            XCTAssertEqual(segments.count, phone ? 0 : ChecklistPhase.allCases.count, "\(size.width) pt")
            XCTAssertTrue(seen.contains { $0.id == "cockpit.phase.preflight" }, "the phase button, \(size.width) pt")
        }
    }

    /// The phase list says what the bar's segments said: each phase's status in words (the dot is colour
    /// alone), the current one selected. The UI tests read and pick a phase there on the phone.
    func testThePhaseListSaysWhatTheBarSaid() throws {
        let services = makeServices()
        startFlight(services.appState, stepByStep: true)
        services.appState.goToPhase(.climb, skipped: .alreadyDone)
        let seen = accessibility(PhaseSelectorView(onSelect: { _ in }), services: services,
                                 size: CGSize(width: 390, height: 1_600))
        for phase in ChecklistPhase.allCases {
            let row = try XCTUnwrap(seen.first { $0.id == "phaseList.\(phase)" }, "\(phase)'s row")
            XCTAssertFalse(row.value.isEmpty, "\(phase)'s status")
            XCTAssertEqual(row.selected, phase == .climb, "\(phase) selected")
        }
        XCTAssertEqual(seen.first { $0.id == "phaseList.descent" }?.value, L10n.Accessibility.phaseNotStarted)
    }

    /// The phone's header holds one height in every phase, the bar drawn in the button and the longest
    /// title ("CHECK BEFORE ENGINE START") on one line: the phase button, the header's last row, keeps its
    /// frame, on a 6.1" phone and on an iPhone SE's 375 pt.
    func testThePhonesHeaderHoldsStillThroughEveryPhase() throws {
        for width in [CGFloat(390), 375] {
            var reference: CGRect?
            for phase in ChecklistPhase.allCases {
                let services = makeServices()
                startFlight(services.appState, stepByStep: true)
                services.appState.currentPhase = phase
                let seen = accessibility(FlightView(initialPane: .checklist), services: services,
                                         size: CGSize(width: width, height: 844))
                let button = try XCTUnwrap(seen.first { $0.id == "cockpit.phase.\(phase)" }?.frame, "\(phase) at \(width)")
                if let reference {
                    XCTAssertEqual(button.minY, reference.minY, accuracy: 0.5, "\(phase): the phase button at \(width) pt")
                    XCTAssertEqual(button.height, reference.height, accuracy: 0.5, "\(phase): its height at \(width) pt")
                } else {
                    reference = button
                }
            }
        }
    }

    // MARK: - The phone on its side (6.2, PR 5)

    /// An iPhone 17 on its side, as the Cockpit has it: the room over the home indicator, less the camera's
    /// side and the other side's 16 pt.
    private static let onItsSide = CGSize(width: 874 - 62 - 16, height: 402 - 20)

    /// The phone on its side: the page on the left (MAP's chart with its own chrome and nothing else, the
    /// next line and the frequency line over it until 6.2 gone; CHECKLIST; ROUTE), the column on the right
    /// with the phase, Menu, the picker, the next line and NOW, and the act band.
    func testOnItsSideThePageIsOnTheLeftAndTheColumnOnTheRight() throws {
        let size = Self.onItsSide
        let columnLeft = size.width - FlightView.cockpitColumnWidth
        for pane in [CockpitPane.map, .checklist, .route] {
            let services = makeServices()
            startFlight(services.appState, stepByStep: false)
            services.appState.goToPhase(.cruise)
            services.locationManager.isTracking = true
            armRoute(services.flightPlanManager)
            let seen = accessibility(FlightView(initialPane: pane), services: services, size: size, wholeWindow: true)
            let ids = Set(seen.map(\.id))
            func frame(_ id: String) throws -> CGRect {
                try XCTUnwrap(seen.first { $0.id == id }?.frame, "\(id) on \(pane): \(ids.sorted())")
            }
            for id in ["cockpit.phase.cruise", "cockpit.menu", "pane.checklist", "pane.map", "pane.route", "read.nextLine",
                       "read.now", "act.more"] {
                XCTAssertGreaterThanOrEqual(try frame(id).minX, columnLeft - 0.5, "\(id) in the column, \(pane)")
            }
            XCTAssertFalse(ids.contains("map.nextLine"), "no next line over the chart, \(pane)")
            XCTAssertFalse(ids.contains("map.frequencies"), "no frequency line under it, \(pane)")
            if pane == .map {
                for id in ["map.orientation", "map.layers", "map.centre"] {
                    XCTAssertLessThan(try frame(id).maxX, columnLeft + 0.5, "\(id) on the chart, left of the column")
                }
            }
            // Where the phase sits in the flight, for VoiceOver: the bar in the button shows it.
            XCTAssertEqual(seen.first { $0.id == "cockpit.phase.cruise" }?.value, "10/16")
        }
    }

    /// The column holds still through every phase: the header's row at its top, the act band at its foot,
    /// whatever the phase's name ("CHECK BEFORE ENGINE START" on one line) and the band's roles.
    func testOnItsSideTheColumnHoldsStillThroughEveryPhase() throws {
        try XCTSkipUnless(CockpitScale.current == .phone, "laid out at the phone's sizes: run it on an iPhone")
        var reference: (phase: CGRect, more: CGRect)?
        for phase in ChecklistPhase.allCases {
            let services = makeServices()
            startFlight(services.appState, stepByStep: true)
            services.appState.currentPhase = phase
            let seen = accessibility(FlightView(initialPane: .checklist), services: services, size: Self.onItsSide,
                                     wholeWindow: true)
            let button = try XCTUnwrap(seen.first { $0.id == "cockpit.phase.\(phase)" }?.frame, "\(phase)")
            let more = try XCTUnwrap(seen.first { $0.id == "act.more" }?.frame, "More in \(phase)")
            if let reference {
                XCTAssertEqual(button, reference.phase, "\(phase): the phase button")
                XCTAssertEqual(more, reference.more, "\(phase): More")
            } else {
                reference = (button, more)
            }
        }
    }

    // MARK: - Helpers

    private final class ZoomHolder: ObservableObject {
        @Published var zoom = 40_000.0
    }

    /// The chrome over a still chart whose zoom the test sets.
    private struct ScaleProbe: View {
        @ObservedObject var holder: ZoomHolder

        var body: some View {
            var model = MapChromeSample.model()
            model.zoom = holder.zoom
            return CockpitMapChrome(model: model, actions: MapChromeActions(), scale: .kneeboard)
                .environment(\.cockpitTheme, .day)
        }
    }

    /// A view in a window, to read its accessibility elements as time passes.
    private struct Hosted {
        let window: UIWindow
        let walk: () -> [Element]

        func settle(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            window.rootViewController?.view.layoutIfNeeded()
        }

        func ids() -> Set<String> { Set(walk().map(\.id)) }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func hosted(_ view: some View, size: CGSize) -> Hosted {
        let host = UIHostingController(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        let window = makeWindow(size: size)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return Hosted(window: window, walk: { [weak host] in host.map { self.elements(in: $0.view) } ?? [] })
    }

    private func makeWindow(size: CGSize) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    override class func setUp() {
        super.setUp()
        enableAccessibilityTree()
    }

    /// SwiftUI builds its views' accessibility elements only for an assistive technology or for UI
    /// automation, and the unit tests' host has neither: what XCUITest turns on, turned on here.
    private static func enableAccessibilityTree() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
    }

    private struct Element {
        let id: String
        let label: String
        let value: String
        let frame: CGRect
        let selected: Bool
    }

    /// What VoiceOver would find in `view`, hosted in a window at `size`. `wholeWindow`: no safe area, the
    /// window's size the view's (a phone on its side, laid out in an upright simulator).
    private func accessibility(_ view: some View, services: Services, size: CGSize, wholeWindow: Bool = false) -> [Element] {
        let host = UIHostingController(rootView: AnyView(environment(view.frame(width: size.width, height: size.height),
                                                                     services)))
        if wholeWindow { host.safeAreaRegions = [] }
        let window = makeWindow(size: size)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        return elements(in: host.view)
    }

    /// The accessibility elements under `view`, as VoiceOver walks them.
    private func elements(in view: UIView) -> [Element] {
        var out: [Element] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 80, visited.insert(ObjectIdentifier(object)).inserted else { return }
            // SwiftUI's elements answer the identifier without declaring `UIAccessibilityIdentification`.
            let getter = NSSelectorFromString("accessibilityIdentifier")
            let id = object.responds(to: getter) ? (object.perform(getter)?.takeUnretainedValue() as? String ?? "") : ""
            if object.isAccessibilityElement || !id.isEmpty {
                out.append(Element(id: id, label: object.accessibilityLabel ?? "", value: object.accessibilityValue ?? "",
                                   frame: object.accessibilityFrame,
                                   selected: object.accessibilityTraits.contains(.selected)))
            }
            if let elements = object.accessibilityElements {
                for element in elements { if let child = element as? NSObject { walk(child, depth: depth + 1) } }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { walk(child, depth: depth + 1) }
                    }
                }
            }
            if let view = object as? UIView {
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
        }
        walk(view, depth: 0)
        return out
    }

    /// What the map and the Cockpit read from the environment, on test storage (as `ViewStackBudgetTests`).
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

    private func environment(_ view: some View, _ services: Services) -> some View {
        view
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
    }

    /// LSZQ to LSGC to LSGN, armed; disarmed when the test ends.
    private func armRoute(_ manager: FlightPlanManager) {
        var plan = manager.createFlightPlan(name: "Map page")
        for (name, latitude, longitude) in [("LSZQ", 47.3923, 7.0296), ("LSGC", 47.0839, 6.7929), ("LSGN", 46.9575, 6.8647)] {
            plan.waypoints.append(FlightPlanWaypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
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
}
