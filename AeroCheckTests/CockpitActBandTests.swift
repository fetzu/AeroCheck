import SwiftUI
import XCTest
import CoreLocation
@testable import AeroCheck

/// The act band (6.2): four slots under every page of the Cockpit, in four frames that never move, the
/// roles following the page and the flight. Until 6.2 each pane had a thumb bar of its own, and the
/// checklist's laid itself out again with the phase: CHECK at the right end, the phase's action, FREDA
/// or the circuit buttons coming and going, so nothing stayed where the thumb had learned it.
@MainActor
final class CockpitActBandTests: XCTestCase {

    // MARK: - Roles

    private let everyPhase = ChecklistPhase.allCases

    func testOnTheChecklistCHECKIsSecondDEFERThirdAndMoreLastInEveryPhase() {
        for phase in everyPhase {
            for route in [false, true] {
                for circuits in [false, true] {
                    for diverting in [false, true] {
                        let roles = ActBandRoles.make(page: .checklist, phase: phase, hasRoute: route,
                                                      diverting: diverting, circuits: circuits)
                        let where_ = "\(phase), route \(route), circuits \(circuits), diverting \(diverting)"
                        XCTAssertEqual(roles.count, 4, where_)
                        XCTAssertEqual(roles[1], .checklistPrimary, where_)
                        XCTAssertEqual(roles[2], .deferItem(enabled: true), where_)
                        XCTAssertEqual(roles[3], .more(withDivert: route), "Divert in More with a leg to fly: \(where_)")
                    }
                }
            }
        }
    }

    func testTheChecklistsFirstSlotIsThePhasesActionThenFREDAThenTheCheckSlot() {
        func first(_ phase: ChecklistPhase, circuits: Bool = false) -> ActSlotRole {
            ActBandRoles.make(page: .checklist, phase: phase, hasRoute: true, circuits: circuits)[0]
        }
        XCTAssertEqual(first(.engineStart), .engineStart)
        XCTAssertEqual(first(.shutdown), .engineShutdown)
        XCTAssertEqual(first(.cruise), .freda)
        XCTAssertEqual(first(.cruise, circuits: true), .checkSlot, "no FREDA in circuits")
        for phase in everyPhase where ![.engineStart, .shutdown, .cruise].contains(phase) {
            XCTAssertEqual(first(phase), .checkSlot, "\(phase): the check slot, its tap the current item (Q11)")
            XCTAssertEqual(first(phase, circuits: true), .checkSlot, "\(phase) in circuits")
        }
    }

    func testDEFERKeepsItsSlotDimmedWhenThereIsNothingToDefer() {
        let roles = ActBandRoles.make(page: .checklist, phase: .climb, hasRoute: false, canDefer: false)
        XCTAssertEqual(roles[2], .deferItem(enabled: false))
    }

    func testOnTheMapTheCheckSlotIsFirstAndMoreLastInEveryPhase() {
        for phase in everyPhase {
            for route in [false, true] {
                for circuits in [false, true] {
                    for landingShown in [false, true] {
                        let roles = ActBandRoles.make(page: .map, phase: phase, hasRoute: route, circuits: circuits,
                                                      landingShown: landingShown)
                        let where_ = "\(phase), route \(route), circuits \(circuits), landing shown \(landingShown)"
                        XCTAssertEqual(roles.count, 4, where_)
                        XCTAssertEqual(roles[0], .checkSlot, where_)
                        guard case .more = roles[3] else { return XCTFail("S4 is More: \(where_)") }
                    }
                }
            }
        }
    }

    func testTheMapWithARouteHasMARKAndDivert() {
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .cruise, hasRoute: true),
                       [.checkSlot, .mark, .divert(enabled: true, diverting: false), .more(withDivert: false)])
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .cruise, hasRoute: true, diverting: true)[2],
                       .divert(enabled: true, diverting: true), "amber while diverting")
        // On the ground too, as the map's bottom row had them in flight.
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .taxi, hasRoute: true)[1], .mark)
        // Every waypoint passed: MARK keeps its place, Divert its own, dimmed.
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .afterLanding, hasRoute: true, routeFlown: true),
                       [.checkSlot, .mark, .divert(enabled: false, diverting: false), .more(withDivert: false)])
    }

    func testTheMapWithoutARouteHasRoutesAndDivertDimmed() {
        for circuits in [false, true] {
            XCTAssertEqual(ActBandRoles.make(page: .map, phase: .climb, hasRoute: false, circuits: circuits),
                           [.checkSlot, .routes, .divert(enabled: false, diverting: false), .more(withDivert: false)])
        }
    }

    func testFromTheApproachTheRunwaysButtonsTakeMARKAndDivertsSlots() {
        for phase in [ChecklistPhase.approach, .landing] {
            for circuits in [false, true] {
                XCTAssertEqual(ActBandRoles.make(page: .map, phase: phase, hasRoute: true, circuits: circuits),
                               [.checkSlot, .goAround, .touchAndGo, .more(withDivert: true)], "\(phase), Divert in More")
                XCTAssertEqual(ActBandRoles.make(page: .map, phase: phase, hasRoute: false, circuits: circuits),
                               [.checkSlot, .goAround, .touchAndGo, .more(withDivert: false)], "\(phase), no route")
            }
        }
        // From circuit height, whatever the phase says: the landing check is shown.
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .climb, hasRoute: false, circuits: true, landingShown: true),
                       [.checkSlot, .goAround, .touchAndGo, .more(withDivert: false)])
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .descent, hasRoute: true, landingShown: true)[1], .goAround)
    }

    // MARK: - The four frames

    /// The band's row on each device: the screen less its padding (16 pt each side on the iPad, 12 on
    /// the phone).
    private enum Row {
        static let iPadPortrait: CGFloat = 820 - 32
        static let iPadOnItsSide: CGFloat = 1180 - 32
        static let iPhone17Pro: CGFloat = 402 - 24
    }

    func testTheFourFramesComeFromTheWidthAlone() {
        for (width, scale) in [(Row.iPadPortrait, CockpitScale.kneeboard), (Row.iPadOnItsSide, .kneeboard),
                               (Row.iPhone17Pro, .phone)] {
            let metrics = ActBandMetrics.make(layout: scale == .phone ? .narrow : .wide, scale: scale)
            let f = ActBandLayout.frames(width: width, metrics: metrics)
            XCTAssertEqual(f.count, 4)
            XCTAssertEqual(f[0].minX, 0)
            XCTAssertEqual(f[3].maxX, width, accuracy: 0.001, "the row's width at \(width) pt")
            XCTAssertEqual(f[0].width, f[1].width, "S1 and S2 share what S3 and S4 leave")
            XCTAssertEqual(f[2].width, metrics.narrowWidth)
            XCTAssertEqual(f[3].width, metrics.narrowWidth)
            for (a, b) in zip(f, f.dropFirst()) {
                XCTAssertEqual(b.minX - a.maxX, metrics.spacing, accuracy: 0.001)
            }
            XCTAssertEqual(Set(f.map(\.height)), [metrics.height], "one height: the thumb's")
            XCTAssertEqual(metrics.height, CockpitType.size(kneeboard: 104, phone: 92, scale: scale))
        }
        // The iPad in portrait: about 250 pt for the slot and CHECK, MARK or GO AROUND; on its side the
        // same frame, wider.
        let iPad = ActBandLayout.frames(width: Row.iPadPortrait, metrics: .make(layout: .wide, scale: .kneeboard))
        XCTAssertGreaterThan(iPad[0].width, 240)
        // The phone: about 100 pt for the slot and CHECK, its item on two lines.
        let phone = ActBandLayout.frames(width: Row.iPhone17Pro, metrics: .make(layout: .narrow, scale: .phone))
        XCTAssertGreaterThanOrEqual(phone[0].width, 98)
        // There, the check slot's "CRUISE CHECK" stays on one line (at most 0.6 of its 19 pt) over its
        // tick, "✓ 14:24", as beside MARK before the band; at 95 pt the tick went.
        XCTAssertLessThanOrEqual(ActBandMetrics.textWidth("CRUISE CHECK", size: 19) * 0.6, phone[0].width - 2 * 6)
    }

    func testThePhoneOnItsSideHasS3OverS4AtHalfHeight() {
        let metrics = ActBandMetrics.make(layout: .columns, scale: .phone)
        let width: CGFloat = 402 - 24
        let f = ActBandLayout.frames(width: width, metrics: metrics)
        XCTAssertEqual(f[2].minX, f[3].minX, "one above the other")
        XCTAssertEqual(f[2].maxX, width, accuracy: 0.001)
        XCTAssertEqual(f[2].height, (92 - 8) / 2)
        XCTAssertEqual(f[3].maxY, 92, accuracy: 0.001, "the band's height, as the thumb row's was")
        XCTAssertEqual(f[0].height, 92)
        XCTAssertEqual(f[0].width, f[1].width)
        XCTAssertGreaterThan(f[0].width, 130, "the slot and MARK keep the room they had")
    }

    /// S3 holds TOUCH-AND-GO on two lines and "Dérouter" at the in-flight label size or larger, on the
    /// iPad and on the phone, and so does every other word of the narrow slots but the phone's French
    /// DEFER ("REPORTER", a little smaller).
    func testTheNarrowSlotsHoldTheirWordsAtTheLabelSize() {
        XCTAssertTrue((120...150).contains(ActBandMetrics.narrowWidth(scale: .kneeboard)))
        XCTAssertTrue((72...80).contains(ActBandMetrics.narrowWidth(scale: .phone)))
        for scale in [CockpitScale.kneeboard, .phone] {
            let room = ActBandMetrics.narrowWidth(scale: scale) - 2 * ActBandMetrics.narrowPadding(scale)
            let size = CockpitType.label(for: scale)
            var words = ["TOUCH-", "AND-GO", "Dérouter", "POSÉ-", "DÉCOLLÉ", "Divert", "More", "Plus", "DEFER"]
            words += ["en", "fr"].flatMap { language in
                ActBandText.twoLines(localizedString(key: "checklist.touchAndGo", language: language))
                    .components(separatedBy: "\n")
            }
            words.append(localizedString(key: "act.divert", language: "fr"))
            for word in words {
                XCTAssertLessThanOrEqual(ActBandMetrics.textWidth(word, size: size), room, "\(word) at \(size) pt, \(scale)")
                // As SwiftUI sets it too.
                let text = Text(verbatim: word).font(.aero(size: size, weight: .bold)).fixedSize()
                XCTAssertLessThanOrEqual(UIHostingController(rootView: text).sizeThatFits(in: CGSize(width: 1_000, height: 100)).width,
                                         room + 0.5, "\(word) as drawn, \(scale)")
            }
        }
        XCTAssertEqual(localizedString(key: "act.divert", language: "fr"), "Dérouter", "the verb on the button")
        XCTAssertEqual(localizedString(key: "act.divert", language: "en"), "Divert")
        // The iPad's French DEFER fits as well; on the phone it is the one word that shrinks a little.
        let reporter = ActBandMetrics.textWidth("REPORTER", size: CockpitType.label(for: .kneeboard))
        XCTAssertLessThanOrEqual(reporter, ActBandMetrics.narrowWidth(scale: .kneeboard) - 2 * ActBandMetrics.narrowPadding(.kneeboard))
        let phoneRoom = ActBandMetrics.narrowWidth(scale: .phone) - 2 * ActBandMetrics.narrowPadding(.phone)
        XCTAssertGreaterThan(phoneRoom / ActBandMetrics.textWidth("REPORTER", size: 17), 0.85)
    }

    /// TOUCH-AND-GO held to confirm, in the narrow slot: its two lines and "Hold to confirm" under them
    /// (two lines too in French) inside the band's height, in both languages, on both devices. At the
    /// hold button's own sizes the four lines took about 108 pt of the iPad's 104.
    func testTouchAndGoHeldFitsTheNarrowSlot() {
        func height(_ text: String, size: CGFloat, lines: Int, width: CGFloat) -> CGFloat {
            let view = Text(verbatim: text).font(.aero(size: size, weight: .bold)).lineLimit(lines)
                .multilineTextAlignment(.center).minimumScaleFactor(0.7)
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000)).height
        }
        for scale in [CockpitScale.kneeboard, .phone] {
            let room = ActBandMetrics.narrowWidth(scale: scale) - 2 * ActBandMetrics.narrowPadding(scale)
            let label = CockpitType.label(for: scale)
            for language in ["en", "fr"] {
                let title = ActBandText.twoLines(localizedString(key: "checklist.touchAndGo", language: language))
                let hint = localizedString(key: "checklist.holdToConfirm", language: language)
                let total = height(title, size: label, lines: 2, width: room) + 2
                    + height(hint, size: label * 0.75, lines: 2, width: room)
                XCTAssertLessThanOrEqual(total, CockpitType.size(kneeboard: 104, phone: 92, scale: scale) - 8,
                                         "\(language), \(scale): \(total) pt")
            }
        }
    }

    func testTwoWordsBreakAtTheirMiddle() {
        XCTAssertEqual(ActBandText.twoLines("TOUCH-AND-GO"), "TOUCH-\nAND-GO")
        XCTAssertEqual(ActBandText.twoLines("POSÉ-DÉCOLLÉ"), "POSÉ-\nDÉCOLLÉ")
        XCTAssertEqual(ActBandText.twoLines("GO AROUND"), "GO\nAROUND")
        XCTAssertEqual(ActBandText.twoLines("REMISE DE GAZ"), "REMISE\nDE GAZ")
        XCTAssertEqual(ActBandText.twoLines("DEFER"), "DEFER", "nowhere to break")
        XCTAssertEqual(ActBandText.twoLines("-GO"), "-GO")
    }

    // MARK: - The band as drawn

    /// Every role set the Cockpit shows, drawn: the four slots in the same four frames, each button as
    /// big as its frame and no bigger, at the iPad's portrait and landscape widths on an iPad, at an
    /// iPhone 17 Pro's and a Pro Max's on an iPhone (a button sizes itself to the device it runs on, so
    /// each device checks its own). On the old thumb bars CHECK was at the right end of the checklist's
    /// and the row changed by phase; MARK was second on the map's.
    func testEveryRoleSetLaysOutInTheSameFourFrames() {
        let cases = [(CGFloat(820), CockpitLayout.wide, CockpitScale.kneeboard), (1180, .wide, .kneeboard),
                     (402, .narrow, .phone), (440, .narrow, .phone)].filter { $0.2 == CockpitScale.current }
        for (screen, layout, scale) in cases {
            let services = makeServices()
            startFlight(services.appState)
            let metrics = ActBandMetrics.make(layout: layout, scale: scale)
            let expected = ActBandLayout.frames(width: screen - (layout == .wide ? 32 : 24), metrics: metrics)
            var roleSets: Set<String> = []
            func draw(_ name: String, page: CockpitPane, _ set: () -> Void) {
                set()
                let slotRoles = roles(page, services)
                roleSets.insert("\(slotRoles)")
                let frames = bandFrames(page: page, layout: layout, scale: scale, width: screen, services: services)
                XCTAssertEqual(frames, expected, "\(name) at \(screen) pt: \(slotRoles)")
            }
            let app = services.appState
            draw("preflight", page: .checklist) { app.currentPhase = .preflight }
            draw("engine start", page: .checklist) { app.currentPhase = .engineStart }
            draw("cruise, FREDA", page: .checklist) { app.currentPhase = .cruise }
            draw("cruise done, NEXT", page: .checklist) {
                app.markLastItemComplete(learningMode: app.effectiveLearningMode)
            }
            draw("shutdown", page: .checklist) { app.currentPhase = .shutdown }
            draw("map, no route", page: .map) { app.currentPhase = .cruise }
            draw("map, route", page: .map) { self.armRoute(services.flightPlanManager) }
            draw("map, landing", page: .map) { app.currentPhase = .landing }
            draw("map, landing in circuits", page: .map) { app.isCircuitMode = true }
            draw("checklist, landing in circuits", page: .checklist) {}
            XCTAssertGreaterThanOrEqual(roleSets.count, 8, "as many role sets, one frame each: \(roleSets.sorted())")
        }
    }

    // MARK: - What the band owns

    func testMARKIsOfferedBackAndTakenBack() throws {
        let manager = activePlan()
        manager.markWaypoint()                                  // the departure, at the take-off
        manager.startChronometer()
        manager.restoreLegTimer(.init(accumulated: 0, startTime: Date().addingTimeInterval(-200)))
        let before = try XCTUnwrap(manager.legTimerSnapshot)
        let nav = CockpitNavState()

        nav.markWaypoint(in: manager, animated: false)
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)
        let offer = try XCTUnwrap(nav.undoOffer)
        XCTAssertTrue(offer.message.contains("LSGC"), offer.message)
        XCTAssertEqual(offer.style, .filled, "the pilot's own tap: filled")

        offer.undo()
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 1, "LSGC the target again")
        XCTAssertNil(manager.activeFlightPlan?.waypoints[1].actualTimeOver)
        XCTAssertEqual(manager.legTimerSnapshot, before)
    }

    func testMARKWithNothingLeftToMarkDoesNothing() {
        let manager = activePlan()
        for _ in 0..<3 { manager.markWaypoint() }
        XCTAssertTrue(manager.isFlightPlanCompleted)
        let nav = CockpitNavState()
        nav.markWaypoint(in: manager, animated: false)
        XCTAssertNil(nav.undoOffer)
    }

    func testTheLegTimerResetIsOfferedBack() throws {
        let manager = activePlan()
        manager.restoreLegTimer(.init(accumulated: 125, startTime: nil))
        let nav = CockpitNavState()
        nav.resetLegTimer(in: manager, animated: false)
        XCTAssertEqual(manager.chronometerElapsed, 0)
        let offer = try XCTUnwrap(nav.undoOffer)
        XCTAssertEqual(offer.message, L10n.Nav.legTimerReset)
        offer.undo()
        XCTAssertEqual(manager.chronometerElapsed, 125)
    }

    func testDivertOpensOnTheFieldAndTheRequestsCount() {
        let nav = CockpitNavState()
        nav.openDivert("LSGC")
        XCTAssertTrue(nav.showDivert)
        XCTAssertEqual(nav.divertPreselect, "LSGC")
        nav.openDivert(nil)
        XCTAssertNil(nav.divertPreselect, "the band's Divert opens on the list")
        let before = nav.checklistScrollRequest
        nav.scrollChecklistToCurrentItem()
        XCTAssertEqual(nav.checklistScrollRequest, before + 1)
        nav.requestLegsPanel()
        XCTAssertTrue(nav.legsPanelPending)
    }

    // MARK: - Helpers

    private func activePlan() -> FlightPlanManager {
        let manager = makeTestPlanManager()
        let plan = FlightPlan(name: "Act band", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
            FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.083, longitude: 6.793)),
            FlightPlanWaypoint(name: "LSGN", coordinate: .init(latitude: 46.958, longitude: 6.864)),
        ])
        manager.add(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        return manager
    }

    private func armRoute(_ manager: FlightPlanManager) {
        var plan = manager.createFlightPlan(name: "Act band")
        for (name, latitude, longitude) in [("LSZQ", 47.3923, 7.0296), ("LSGC", 47.0839, 6.7929), ("LSGN", 46.9575, 6.8647)] {
            plan.waypoints.append(FlightPlanWaypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        }
        plan.calculateRouteData()
        manager.updateFlightPlan(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.deactivateFlightPlan() }
    }

    private func roles(_ page: CockpitPane, _ services: Services) -> [ActSlotRole] {
        let app = services.appState, plans = services.flightPlanManager
        return ActBandRoles.make(page: page, phase: app.currentPhase, hasRoute: plans.activeFlightPlan != nil,
                                 routeFlown: plans.isFlightPlanCompleted, circuits: app.isCircuitMode,
                                 landingShown: app.landingCheckShown,
                                 canDefer: !app.currentCheckIsDone && !app.currentCheckAwaitsConfirmation)
    }

    /// The band drawn `width` wide, and each slot's frame as laid out.
    private func bandFrames(page: CockpitPane, layout: CockpitLayout, scale: CockpitScale, width: CGFloat,
                            services: Services) -> [CGRect] {
        final class Box { var frames: [Int: CGRect] = [:] }
        let box = Box()
        let band = CockpitActBand(page: page, layout: layout, actions: CockpitActions(), scale: scale,
                                  onPlace: { box.frames[$0] = $1 })
        render(band, services: services, size: CGSize(width: width, height: 200))
        return (0..<4).map { box.frames[$0] ?? .zero }
    }

    /// What the band reads from the environment, on test storage (as `ViewStackBudgetTests`).
    private struct Services {
        let appState: AppState
        let subscriptionManager: SubscriptionManager
        let aircraftDataService: AircraftDataService
        let flightPlanManager: FlightPlanManager
        let threadManager: FlightThreadManager
        let locationManager: LocationManager
        let airportDataService: AirportDataService
        let openAIPDataService: OpenAIPDataService
        let flightEventDetector: FlightEventDetector
        let navState: CockpitNavState
    }

    private func makeServices() -> Services {
        let datastore = makeTestDatastore()
        let subscriptionManager = makeTestSubscriptionManager(deferLoadProducts: true)
        let airportDataService = AirportDataService()
        airportDataService.isDownloading = true
        return Services(
            appState: makeTestAppState(datastore: datastore),
            subscriptionManager: subscriptionManager,
            aircraftDataService: makeTestAircraftDataService(subscriptionManager: subscriptionManager),
            flightPlanManager: makeTestPlanManager(datastore: datastore),
            threadManager: makeTestThreadManager(datastore: datastore),
            locationManager: LocationManager(),
            airportDataService: airportDataService,
            openAIPDataService: OpenAIPDataService(),
            flightEventDetector: FlightEventDetector(),
            navState: CockpitNavState()
        )
    }

    /// A flight with the bundled WT9, every item to check one by one, cancelled when the test ends.
    private func startFlight(_ appState: AppState) {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
    }

    private func render<V: View>(_ view: V, services: Services, size: CGSize) {
        let content = view
            .frame(width: size.width)
            .environment(services.appState)
            .environment(services.navState)
            .environment(\.cockpitTheme, CockpitTheme.resolve(.day))
            .environmentObject(services.locationManager)
            .environmentObject(services.flightPlanManager)
            .environmentObject(services.airportDataService)
            .environmentObject(services.aircraftDataService)
            .environmentObject(services.openAIPDataService)
            .environmentObject(services.flightEventDetector)
            .environmentObject(services.threadManager)
            .environmentObject(services.subscriptionManager)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: nil)
        _ = renderer.uiImage
    }
}
