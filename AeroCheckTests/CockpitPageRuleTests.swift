import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// Which page the Cockpit shows by itself (v6.0 · P2): the map en route once the phase's checklist is
/// done, the checklist everywhere else and whenever one is open.
final class CockpitPageRuleTests: XCTestCase {

    func testEnRouteTheMapOnceTheChecklistIsDone() {
        for phase in [ChecklistPhase.climb, .cruise, .descent] {
            XCTAssertEqual(CockpitPageRule.defaultPage(phase: phase, checklistDone: true), .map, "\(phase)")
        }
    }

    func testEnRouteTheChecklistWhileItIsOpen() {
        // Entering climb shows the climb checklist; a cruise check come due brings the list back.
        for phase in [ChecklistPhase.climb, .cruise, .descent] {
            XCTAssertEqual(CockpitPageRule.defaultPage(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
    }

    /// ROUTE is the pilot's pick only: the flight never suggests it, in any phase or state. (6.2)
    func testROUTEIsNeverWhatTheFlightSuggests() {
        for phase in ChecklistPhase.allCases {
            for done in [false, true] {
                for memory in [false, true] {
                    XCTAssertNotEqual(CockpitPageRule.defaultPage(phase: phase, checklistDone: done, memoryCheck: memory),
                                      .route, "\(phase), done \(done), memory \(memory)")
                }
            }
        }
    }

    func testAPickedPageHoldsUntilTheSuggestionChanges() {
        var choice = CockpitPageChoice()
        XCTAssertEqual(choice.page(suggested: .checklist), .checklist)
        choice.pick(.route, suggested: .checklist)
        XCTAssertEqual(choice.page(suggested: .checklist), .route, "ROUTE picked over the checklist")
        // The flight moves on (the checklist done, the next phase): the pick is dropped, ROUTE's too.
        choice.suggestionChanged()
        XCTAssertEqual(choice.page(suggested: .map), .map)
        XCTAssertNil(choice.override)
    }

    func testPickingTheSuggestedPageClearsThePick() {
        var choice = CockpitPageChoice(override: .route)
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
            XCTAssertEqual(CockpitPageRule.defaultPage(phase: phase, checklistDone: true), .checklist, "\(phase)")
            XCTAssertEqual(CockpitPageRule.defaultPage(phase: phase, checklistDone: false), .checklist, "\(phase)")
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

/// A phone on its side (6.2, PR 5): the page on the left at full height, the column on the right, with the
/// header on one row, the pages' picker, the strip at 28 pt, the next and NOW lines (one line under 400 pt
/// tall) and the act band two by two at its foot, every row whole between the top of the screen and the home
/// indicator, on CHECKLIST, MAP, ROUTE and in the approach (GO AROUND, TOUCH-AND-GO), with the checklist in
/// English and in French. Run it with `-testLanguage fr` too: the phase names, CARTE and ACT are the app's.
///
/// The column was on the left until 6.2, and about 440 pt tall where a phone on its side has 370 to 420:
/// the strip's values shrank to about half, then the thumb row ran off the screen (6.1, device check of 3
/// Oct). On main before this PR it was 374 pt in an iPhone 17e's 370, the thumb row's 12 pt of padding
/// hiding the overflow from this test's 2 pt look at its foot.
///
/// Laid out at the phone's sizes (`CockpitScale`), so it runs on an iPhone simulator; on the iPad the
/// suite runs on, it is skipped.
@MainActor
final class CockpitColumnFitTests: XCTestCase {

    /// The phones on their side, as the Cockpit has them: the room over the home indicator (20 pt), less
    /// the camera's side (47 or 62 pt) and the other side's 16 (`CameraSideInset`). Measured on iOS 27
    /// simulators. The iPhone 17e is 390 pt wide in portrait.
    static let phones: [(name: String, size: CGSize)] = [
        ("iPhone 17e", CGSize(width: 844 - 47 - 16, height: 390 - 20)),
        ("iPhone 17", CGSize(width: 874 - 62 - 16, height: 402 - 20)),
        ("iPhone 17 Pro Max", CGSize(width: 956 - 62 - 16, height: 440 - 20)),
    ]

    /// The pages and the states the column holds through: the band's roles change with them, the column's
    /// rows never do.
    enum Page: String, CaseIterable {
        /// Cruise, the list open: FREDA, CHECK with the item, DEFER, More.
        case checklist
        /// Cruise with a route: the check slot, MARK with the leg time, Divert, More.
        case map
        /// Cruise with a route: the DEST line, the legs, the radio.
        case route
        /// The approach on MAP: the check slot, GO AROUND, TOUCH-AND-GO, More.
        case approach
        /// The longest phase name on the header's row: "CHECK BEFORE ENGINE START", no strip yet.
        case beforeEngineStart
    }

    func testTheColumnFitsOnEveryPhoneOnEveryPage() throws {
        try XCTSkipUnless(CockpitScale.current == .phone, "laid out at the phone's sizes: run it on an iPhone")
        let interface = Bundle.main.preferredLocalizations.first ?? "en"
        for phone in Self.phones {
            for page in Page.allCases {
                for language in [ChecklistLanguage.en, .fr] {
                    let services = makeServices()
                    let shown = setUp(page, language: language, services: services)
                    let image = try render(FlightView(initialPage: shown), services: services, size: phone.size)
                    let column = try columnPixels(image)
                    let name = "\(phone.name), \(page.rawValue), checklist \(language.rawValue), app \(interface)"
                    try writeForReview(image, name: name)
                    XCTAssertTrue(column.topIsClear, "\(name): the header runs off the top")
                    XCTAssertTrue(column.footIsClear, "\(name): the act band runs off the foot")
                    XCTAssertTrue(column.edgeAtFullHeight, "\(name): the column's edge from the top to the foot, the page left of it")
                }
            }
        }
    }

    /// The header's one row: every phase's name at 17 pt beside Menu, in English and in French, in the
    /// column's width (`FlightView.cockpitColumnWidth`): its 12 pt either side, Menu (the word under its
    /// icon, 10 pt either side), 8 pt between them, the phase button's 10 pt either side. "CHECK BEFORE
    /// ENGINE START" sets the width.
    func testEveryPhaseNameFitsTheHeadersRowAtTheLabelSize() {
        let label = CockpitType.label(for: .phone)
        let menu = ActBandMetrics.textWidth(localizedString(key: "cockpit.menu", language: "en"), size: label) + 2 * 10
        let room = FlightView.cockpitColumnWidth - 2 * 12 - menu - 8 - 2 * 10
        var widest: (String, CGFloat) = ("", 0)
        for language in ["en", "fr"] {
            for phase in Self.phases {
                let name = localizedString(key: "phase.short.\(phase)", language: language)
                let width = ActBandMetrics.textWidth(name, size: label)
                if width > widest.1 { widest = (name, width) }
                XCTAssertLessThanOrEqual(width, room, "\(name) at \(label) pt in \(room) pt")
            }
        }
        XCTAssertEqual(widest.0, "CHECK BEFORE ENGINE START")
    }

    /// The column's rows, added up, within each phone's height (the author's answer to the plan's Q2): 2 pt
    /// over the header's row, its 44, 4, the picker's 46, 4, the read band's rows as laid out (the strip at
    /// 28 pt and one line, or two on a Pro Max), the act band's 2 × 76 + 6 with 4 over and 2 under it. The
    /// pixels above see the column run over; this says by how much it has room.
    func testTheColumnsRowsAddUpWithinEveryPhone() throws {
        try XCTSkipUnless(CockpitScale.current == .phone, "laid out at the phone's sizes: run it on an iPhone")
        let width = FlightView.cockpitColumnWidth
        let band = ActBandMetrics.make(layout: .columns, scale: .phone).bandHeight
            + CockpitActBand.columnTopPadding + CockpitActBand.columnBottomPadding
        let head = FlightView.cockpitColumnTop + FlightView.cockpitColumnHeaderHeight + FlightView.cockpitColumnGap
            + CockpitPagePicker.compactSegmentHeight + 2 * 2 + FlightView.cockpitColumnGap
        let strip = StripReading(speedKnots: 104, targetSpeed: 100, gpsSignalStatus: .good, altitudeFeet: 10_500,
                                 headingDegrees: 211, verticalSpeedFPM: 650)
        for phone in Self.phones {
            let merges = CockpitColumnRule.mergesNextAndNow(height: phone.size.height)
            let rows = CockpitReadRows(layout: .columns, mergesLines: merges, scale: .phone, strip: strip,
                                       next: NextFigures(ident: "SAIGNELÉGIER", fullIdent: nil, diverting: false, bearing: 206,
                                                         distanceNM: 17.6, live: nil),
                                       now: PhaseFrequency(station: "LSZQ AFIS", freq: "120.375", highlighted: true,
                                                           isEmergency: false, role: .current),
                                       nextFrequency: nil, onShowRoute: {})
                .environment(\.cockpitTheme, CockpitTheme.resolve(.day))
            let height = UIHostingController(rootView: rows.frame(width: width))
                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let total = head + height + band
            XCTAssertLessThanOrEqual(total, phone.size.height,
                                     "\(phone.name): \(total) pt of \(phone.size.height) (the read band \(height))")
        }
    }

    /// The next and NOW lines merge under 400 pt tall: the 17e and the 17, not the Pro Max.
    func testTheLinesMergeOnTheSmallerPhones() {
        XCTAssertEqual(Self.phones.map { CockpitColumnRule.mergesNextAndNow(height: $0.size.height) }, [true, true, false])
        XCTAssertTrue(CockpitColumnRule.mergesNextAndNow(height: 399))
        XCTAssertFalse(CockpitColumnRule.mergesNextAndNow(height: 400))
    }

    /// Writes `image` as a PNG into the folder named by COLUMN_SHOTS (`TEST_RUNNER_COLUMN_SHOTS` on
    /// xcodebuild's command line), for review. Nothing without it.
    private func writeForReview(_ image: CGImage, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["COLUMN_SHOTS"], !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = name.lowercased().replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "-") + ".png"
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        try data.write(to: directory.appendingPathComponent(file))
    }

    private static let phases = ["preflight", "beforeEngineStart", "engineStart", "afterEngineStart", "taxi", "runup",
                                 "beforeDeparture", "lineUp", "climb", "cruise", "descent", "approach", "landing",
                                 "afterLanding", "shutdown", "hangar"]

    /// The flight for `page`, and the page to open on.
    private func setUp(_ page: Page, language: ChecklistLanguage, services: Services) -> CockpitPage {
        let appState = services.appState
        appState.settings.checklistLanguage = language
        switch page {
        case .checklist:
            startFlight(appState, stepByStep: true)
            appState.currentPhase = .cruise
            return .checklist
        case .map, .route:
            startFlight(appState, stepByStep: false)
            appState.goToPhase(.cruise)
            armRoute(services.flightPlanManager)
            return page == .map ? .map : .route
        case .approach:
            startFlight(appState, stepByStep: false)
            appState.goToPhase(.approach)
            armRoute(services.flightPlanManager)
            return .map
        case .beforeEngineStart:
            startFlight(appState, stepByStep: true)
            appState.currentPhase = .beforeEngineStart
            return .checklist
        }
    }

    /// The column's first and last rows across its width, against its own background: clear when the header
    /// and the band keep their 2 pt from the edges (the buttons' strokes reach half a point into them), drawn
    /// when the column runs 2 pt or more over the phone's height. And its left edge, drawn from the top to
    /// the foot: the column on the right at full height, the page beside it.
    private func columnPixels(_ image: CGImage) throws -> (topIsClear: Bool, footIsClear: Bool, edgeAtFullHeight: Bool) {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = bytes + y * perRow + x * perPixel
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        let left = image.width - Int(FlightView.cockpitColumnWidth)
        // The column's own background: its right margin, at its foot.
        let background = pixel(image.width - 4, image.height - 1)
        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let (a, b, c) = pixel(x, y)
            return abs(a - background.0) <= 3 && abs(b - background.1) <= 3 && abs(c - background.2) <= 3
        }
        let columns = (left + 12)..<(image.width - 12)
        let footIsClear = columns.allSatisfy { isBackground($0, image.height - 1) }
        let topIsClear = columns.allSatisfy { isBackground($0, 0) }
        let edge = (0..<image.height).allSatisfy { !isBackground(left, $0) }
        return (topIsClear, footIsClear, edge)
    }
    // MARK: - Helpers

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
