import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// The Cockpit's undo offer (6.2): one at a time, the newest made, for six seconds of the pilot's time
/// from when it was made, whichever page shows it; a newer offer ends the older ones for good
/// (`UndoOfferRule`, `NavUndoOffer.shown`). And the toast on the phone, compact enough to leave a page's
/// legs in view.
///
/// Found by the ground replays (flight-7 and flight-8, 4 Oct): INS marked on its own at 12:00, FREDA
/// done at 12:01 took its place in MAP's slot, and at 12:02 CHECKLIST offered INS's UNDO again, with six
/// fresh seconds.
@MainActor
final class UndoOfferTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        FlightClock.virtual = nil
        super.tearDown()
    }

    /// The flight's clock stopped at `t0 + seconds` (the pilot's seconds, at rate 0).
    private func at(_ seconds: TimeInterval) {
        FlightClock.virtual = .init(wallAnchor: Date(), virtualAnchor: t0.addingTimeInterval(seconds), rate: 0)
    }

    private func candidate(_ seconds: TimeInterval) -> UndoOfferRule.Candidate {
        .init(id: UUID(), madeAt: t0.addingTimeInterval(seconds))
    }

    // MARK: - The rule

    /// Two offers a second apart: the newer shows, for six seconds from when it was made; the older never
    /// again, though its source still holds it.
    func testTwoOffersASecondApartTheNewerShowsForItsSixSeconds() {
        let older = candidate(0), newer = candidate(1)
        at(2)
        XCTAssertEqual(UndoOfferRule.current([older, newer], lastMadeAt: newer.madeAt), newer)
        XCTAssertEqual(UndoOfferRule.current([newer, older], lastMadeAt: newer.madeAt), newer, "whatever the order")
        at(6.9)
        XCTAssertEqual(UndoOfferRule.current([older, newer], lastMadeAt: newer.madeAt), newer, "5.9 s old")
        at(7)
        XCTAssertNil(UndoOfferRule.current([older, newer], lastMadeAt: newer.madeAt), "its six seconds are up")
    }

    /// The newer gone before its six seconds (UNDO, or its source dropping it): the older doesn't come back.
    func testAnOlderOfferNeverComesBack() {
        let older = candidate(0), newer = candidate(1)
        at(2)
        XCTAssertNil(UndoOfferRule.current([older], lastMadeAt: newer.madeAt))
        XCTAssertEqual(UndoOfferRule.current([older], lastMadeAt: nil), older, "with no newer known, it shows")
        XCTAssertEqual(UndoOfferRule.lastMadeAt(nil, older.madeAt, newer.madeAt), newer.madeAt)
        XCTAssertNil(UndoOfferRule.lastMadeAt(nil, nil))
    }

    /// Two at the same instant: the first given (the check, then the waypoint, then the band's).
    func testTwoAtTheSameInstantTheFirstGiven() {
        let check = candidate(0), band = UndoOfferRule.Candidate(id: UUID(), madeAt: t0)
        at(1)
        XCTAssertEqual(UndoOfferRule.current([check, band], lastMadeAt: t0), check)
    }

    /// A page that comes four seconds into an offer has two left, not six: the six seconds are the
    /// offer's, not the page's.
    func testAPageSwitchMidOfferKeepsItsSixSeconds() {
        at(4)
        XCTAssertEqual(UndoOfferRule.remaining(t0), 2, accuracy: 1e-9)
        at(0)
        XCTAssertEqual(UndoOfferRule.remaining(t0), 6, accuracy: 1e-9)
        at(9)
        XCTAssertEqual(UndoOfferRule.remaining(t0), 0)
        XCTAssertFalse(UndoOfferRule.isLive(t0))
        XCTAssertEqual(UndoOfferRule.window, AppState.memoryConfirmationUndoWindow)
        XCTAssertEqual(UndoCountdown.window, UndoOfferRule.window)
    }

    /// A replay's ten times: six seconds of the pilot's are a minute of the flight's clock.
    func testTheSixSecondsAreThePilotsInAReplay() {
        FlightClock.virtual = .init(wallAnchor: Date(), virtualAnchor: t0.addingTimeInterval(30), rate: 10)
        XCTAssertEqual(UndoOfferRule.remaining(t0), 3, accuracy: 0.2)
    }

    // MARK: - The sources

    /// The replays' flight-7 and flight-8: a waypoint marked on its own, a check done a second later.
    /// The check's offer shows; once it goes (its UNDO, or its seconds), the waypoint's doesn't come back,
    /// though the flight still holds its notice.
    func testACheckDoneAfterAnAutomaticMarkEndsItForGood() throws {
        let flight = try Flight(test: self)
        at(0)
        flight.autoMarkLSGC()
        let notice = try XCTUnwrap(flight.plans.autoMarkNotice)
        XCTAssertEqual(flight.shown()?.id, notice.id)

        at(1)
        flight.confirmLandingFromMemory()
        let confirmation = try XCTUnwrap(flight.appState.memoryConfirmation)
        XCTAssertEqual(flight.shown()?.id, confirmation.id, "the newer, whatever its kind")

        at(3)
        flight.appState.dismissCheckConfirmation(confirmation.id)        // the slot's or the toast's end
        XCTAssertNotNil(flight.plans.autoMarkNotice, "the flight still holds it")
        XCTAssertNil(flight.shown(), "LSGC's UNDO doesn't come back")
        XCTAssertNil(flight.shown(onMap: true))
        at(60)
        XCTAssertNil(flight.shown())
    }

    /// MARK a second after a check done: MARK's UNDO shows (until 6.2 a check's offer came first by kind,
    /// and hid it), and the check's doesn't come back after it.
    func testMarkAfterACheckIsTheOneShown() throws {
        let flight = try Flight(test: self)
        at(0)
        flight.confirmLandingFromMemory()
        at(1)
        flight.nav.markWaypoint(in: flight.plans, animated: false)
        let mark = try XCTUnwrap(flight.nav.undoOffer)
        XCTAssertEqual(flight.shown()?.id, mark.id)
        XCTAssertEqual(flight.shown(onMap: true)?.id, mark.id, "MAP's slot says the same")
        at(2)
        flight.nav.undoOffer = nil                                       // its UNDO tapped
        XCTAssertNil(flight.shown(), "the check's doesn't come back")
    }

    /// The newest dropped by its own source, not by the pilot: DIRECT drops a waypoint's notice. The check
    /// done before it doesn't come back either.
    func testAnOfferDroppedByItsSourceLeavesNothingOlderBehind() throws {
        let flight = try Flight(test: self)
        at(0)
        flight.confirmLandingFromMemory()
        at(1)
        flight.autoMarkLSGC()
        XCTAssertEqual(flight.shown()?.id, flight.plans.autoMarkNotice?.id)
        flight.plans.directTo(waypointAt: 2)
        XCTAssertNil(flight.plans.autoMarkNotice)
        XCTAssertNil(flight.shown())
    }

    /// The offer's own seconds, not the page's: a check done five seconds ago still shows, and goes a
    /// second later on any page; one made seven seconds ago shows nowhere.
    func testAnOfferShowsForItsOwnSixSecondsOnEveryPage() throws {
        let flight = try Flight(test: self)
        at(0)
        flight.confirmLandingFromMemory()
        at(5)
        XCTAssertNotNil(flight.shown())
        XCTAssertNotNil(flight.shown(onMap: true))
        at(7)
        XCTAssertNil(flight.shown())
        XCTAssertNil(flight.shown(onMap: true))
    }

    // MARK: - The views

    /// The toast and MAP's slot shown five seconds into an offer (a page switch) go a second later, not
    /// six: they wait what is left of the offer's.
    func testAViewThatComesLateGoesWithTheOffer() {
        for slot in [false, true] {
            let ended = Ended()
            let offer = NavUndoOffer(message: "LSGC passed at 10:58", madeAt: Date().addingTimeInterval(-5)) {}
            let view: AnyView = slot
                ? AnyView(MapUndoSlot(offer: offer, metrics: MapChromeGeometry.Metrics(.kneeboard)) { ended.at = Date() })
                : AnyView(NavUndoToast(offer: offer) { ended.at = Date() })
            let start = Date()
            let window = host(view, size: CGSize(width: 480, height: 120))
            RunLoop.current.run(until: start.addingTimeInterval(0.4))
            XCTAssertNil(ended.at, slot ? "the slot, not yet" : "the toast, not yet")
            RunLoop.current.run(until: start.addingTimeInterval(1.8))
            let after = ended.at.map { $0.timeIntervalSince(start) }
            XCTAssertNotNil(after, slot ? "the slot went with the offer" : "the toast went with the offer")
            XCTAssertLessThan(after ?? 99, 1.6)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    // MARK: - The phone's toast

    /// On the phone the toast is compact: UNDO a control tall (50 pt, over the 44 pt minimum), the message
    /// at 17 pt on two lines (the longest, with a 12-letter waypoint, in English and French, on an iPhone SE's
    /// 375 pt too), about 62 pt in all where the kneeboard's is over 100. Three lines only for French with a
    /// 12-hour clock, still under 80 pt, never cut.
    func testThePhonesToastIsCompactAndHoldsTheLongestMessages() throws {
        let compact = NavUndoToast.Metrics(compact: true)
        XCTAssertEqual(compact.buttonHeight, 50)
        XCTAssertGreaterThanOrEqual(compact.buttonHeight, 44)
        XCTAssertEqual(NavUndoToast.Metrics(compact: false).buttonHeight, 78, "the kneeboard's 15 mm UNDO")
        let font = UIFont.aero(size: CockpitType.label(for: .phone), weight: .semibold)
        for language in ["en", "fr"] {
            for clock in ["22:58", "10:58 PM"] {
                for kind in MapChromeSample.UndoKind.allCases {
                    let message = MapChromeSample.undoMessage(kind, language: language, time: clock)
                    let offer = NavUndoOffer(message: message, style: .outlined) {}
                    let rare = language == "fr" && clock.hasSuffix("PM")
                    for width in [CGFloat(375), 390, 402] {
                        // The page's margins: 12 pt either side on the phone (`AutoMarkUndoToast`).
                        let height = fittingHeight(NavUndoToast(offer: offer, compact: true) {}, width: width - 24)
                        XCTAssertLessThanOrEqual(height, rare ? 80 : 66, "\(kind), \(language), \(clock), \(width) pt: \(height) pt tall")
                        let text = width - 24 - compact.leading - compact.trailing - compact.spacing - compact.buttonMinWidth
                        let lines = (fittingHeight(Text(message).font(.aero(size: CockpitType.label(for: .phone), weight: .semibold)),
                                                   width: text) / font.lineHeight).rounded()
                        XCTAssertLessThanOrEqual(lines, Double(rare ? compact.messageLines : 2),
                                                 "\(kind), \(language), \(clock), \(width) pt: \(message)")
                    }
                }
            }
            let undo = localizedString(key: "nav.undo", language: language, defaultValue: "Undo").uppercased()
            XCTAssertLessThanOrEqual(UIFont.aero(size: 17, weight: .heavy).width(of: undo) + 12, compact.buttonMinWidth,
                                     "\(undo) inside its button")
        }
        let kneeboard = NavUndoToast(offer: NavUndoOffer(message: "LSGC passed at 10:58", undo: {}), compact: false) {}
        XCTAssertGreaterThan(fittingHeight(kneeboard, width: 760), 90, "the kneeboard's keeps its 15 mm UNDO")
    }

    // MARK: - Helpers

    private final class Ended {
        var at: Date?
    }

    private func host(_ view: AnyView, size: CGSize) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view.environment(\.cockpitTheme, .day))
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func fittingHeight(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view.environment(\.cockpitTheme, .day))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// A flight with the WT9 in the landing check (a memory check with the Memory test on), a route armed
    /// LSZQ → LSGC → LSGN, the act band's state: the three places an undo offer comes from.
    @MainActor
    private final class Flight {
        let appState: AppState
        let plans: FlightPlanManager
        let nav = CockpitNavState()
        private let lszq = CLLocationCoordinate2D(latitude: 47.392, longitude: 7.030)
        private let lsgc = CLLocationCoordinate2D(latitude: 47.083, longitude: 6.793)
        private let lsgn = CLLocationCoordinate2D(latitude: 46.958, longitude: 6.864)

        init(test: XCTestCase) throws {
            let datastore = test.makeTestDatastore()
            appState = test.makeTestAppState(datastore: datastore)
            appState.settings.selectedRemoteAircraftId = nil
            appState.settings.selectedAircraft = .wt9Dynamic
            appState.settings.learningMode = false
            appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
            plans = test.makeTestPlanManager(datastore: datastore)
            let plan = FlightPlan(name: "Undo", waypoints: [
                FlightPlanWaypoint(name: "LSZQ", coordinate: lszq),
                FlightPlanWaypoint(name: "LSGC", coordinate: lsgc),
                FlightPlanWaypoint(name: "LSGN", coordinate: lsgn),
            ])
            plans.add(plan)
            plans.activateFlightPlan(plan)
            plans.startChronometer()
            test.addTeardownBlock { @MainActor [plans, appState] in
                plans.stopChronometer()
                appState.cancelFlight()
            }
        }

        /// The landing check confirmed from memory: a check's offer.
        func confirmLandingFromMemory() {
            appState.currentPhase = .landing
            appState.confirmMemoryCheck()
        }

        /// LSGC passed and marked by the flight's own catch-up: a waypoint's offer.
        func autoMarkLSGC() {
            let takeoff = FlightClock.now.addingTimeInterval(-3600)
            let halfWay = CLLocationCoordinate2D(latitude: (lsgc.latitude + lsgn.latitude) / 2,
                                                 longitude: (lsgc.longitude + lsgn.longitude) / 2)
            plans.catchUpWaypointPassages(track: track([lszq, lsgc, halfWay], from: takeoff), takeoff: takeoff,
                                          flightPlanId: plans.activeFlightPlan?.id)
        }

        func shown(onMap: Bool = false) -> NavUndoOffer? {
            NavUndoOffer.shown(in: appState, flightPlanManager: plans, cockpitNav: nav, flightOnly: onMap)
        }

        /// A fix every 10 s at 100 kt along `corners`, from `start`.
        private func track(_ corners: [CLLocationCoordinate2D], from start: Date) -> [GPSPoint] {
            var points: [GPSPoint] = []
            var t = start
            for (a, b) in zip(corners, corners.dropFirst()) {
                let nm = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852
                let steps = max(1, Int((nm / (100.0 / 360)).rounded(.up)))
                for i in 0..<steps {
                    let f = Double(i) / Double(steps)
                    points.append(GPSPoint(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                           longitude: a.longitude + (b.longitude - a.longitude) * f,
                                           altitude: 1500, timestamp: t, speed: 51))
                    t = t.addingTimeInterval(10)
                }
            }
            return points
        }
    }
}

private extension UIFont {
    func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: self]).width
    }
}
