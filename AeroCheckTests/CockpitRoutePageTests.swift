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
        let legsScroll = try XCTUnwrap(parts[.legsScroll])
        XCTAssertGreaterThanOrEqual(radio.minY, legsScroll.maxY, "RADIO under LEGS")
        XCTAssertEqual(legs.minX, 16)
        XCTAssertEqual(radio.minX, 16)
        XCTAssertEqual(radio.width, 402 - 32, "the page's width")
    }

    /// A short route on a phone: LEGS takes what its rows need, RADIO the rest.
    func testOnAPhoneAShortRoutesLegsTakeOnlyTheirRows() throws {
        let parts = try layOut(waypoints: 3, size: CGSize(width: 402, height: 640), layout: .narrow)
        let legs = try XCTUnwrap(parts[.legs]), legsScroll = try XCTUnwrap(parts[.legsScroll])
        let scroll = try XCTUnwrap(parts[.scroll])
        XCTAssertLessThan(legsScroll.height, scroll.height * RouteLegsAndRadio.phoneLegsShare - 20, "no empty half page")
        XCTAssertLessThanOrEqual(legs.height, legsScroll.height, "every row in view, no scroll")
    }

    /// A long route: LEGS scrolls on its own and RADIO stays at the top of its own scroll, NOW and NEXT in
    /// view, on the iPad and on a phone (on a phone, LEGS over at most half the page). In one scroll the
    /// legs took RADIO off the page. (6.2 device check)
    func testRadioStaysInViewHoweverLongTheLegs() throws {
        for (layout, size) in [(CockpitLayout.wide, CGSize(width: 820, height: 700)),
                               (.narrow, CGSize(width: 402, height: 640))] {
            let parts = try layOut(waypoints: 20, size: size, layout: layout)
            let legs = try XCTUnwrap(parts[.legs]), radio = try XCTUnwrap(parts[.radio])
            let legsScroll = try XCTUnwrap(parts[.legsScroll]), radioScroll = try XCTUnwrap(parts[.radioScroll])
            let scroll = try XCTUnwrap(parts[.scroll]), emergency = try XCTUnwrap(parts[.emergency])
            XCTAssertGreaterThan(legs.height, legsScroll.height, "\(layout): twenty legs scroll")
            XCTAssertEqual(radio.minY, radioScroll.minY + 12, accuracy: 0.5, "\(layout): RADIO at the top of its own scroll")
            XCTAssertLessThanOrEqual(radioScroll.maxY, emergency.minY + 0.5, "\(layout): above Emergency")
            if layout == .wide {
                XCTAssertEqual(radioScroll.minY, legsScroll.minY, "side by side")
                XCTAssertEqual(radioScroll.height, legsScroll.height, "the page's height each")
            } else {
                XCTAssertLessThanOrEqual(legsScroll.height, scroll.height * RouteLegsAndRadio.phoneLegsShare + 0.5,
                                         "a phone's LEGS: half the page at most")
                XCTAssertGreaterThanOrEqual(radioScroll.minY, legsScroll.maxY, "RADIO under it")
                XCTAssertGreaterThan(radioScroll.height, 150, "room for NOW, NEXT and more")
            }
        }
    }

    func testEmergencyIsPinnedWholeUnderTheScrolls() throws {
        // Twenty legs: more than the page, so the legs scroll.
        let size = CGSize(width: 820, height: 600)
        let parts = try layOut(waypoints: 20, size: size)
        let scroll = try XCTUnwrap(parts[.scroll]), emergency = try XCTUnwrap(parts[.emergency])
        let legs = try XCTUnwrap(parts[.legs]), radio = try XCTUnwrap(parts[.radio])
        XCTAssertGreaterThan(legs.height, scroll.height, "the legs run past the page: they scroll")
        XCTAssertGreaterThanOrEqual(emergency.minY, scroll.maxY, "Emergency is outside the scrolls, under them")
        XCTAssertLessThanOrEqual(emergency.maxY, size.height, "whole, on the page")
        XCTAssertGreaterThan(emergency.height, 40, "a frequency row, not squeezed")
        XCTAssertGreaterThanOrEqual(legs.minY, scroll.minY)
        XCTAssertGreaterThanOrEqual(radio.minY, scroll.minY)
    }

    /// The undo toast lies over Emergency and a little of the scroll for six seconds: the scroll keeps that
    /// much room at its foot, so the leg being flown, brought into view, is never under it. The phone's
    /// toast is the compact one; a message on its two lines. (6.2)
    func testTheScrollKeepsTheUndoToastsReachAtItsFoot() throws {
        let offer = NavUndoOffer(message: "SAIGNELÉGIER marked automatically at 10:58 PM", style: .outlined) {}
        for (layout, size) in [(CockpitLayout.narrow, CGSize(width: 390, height: 520)),
                               (.narrow, CGSize(width: 402, height: 520)), (.wide, CGSize(width: 820, height: 700))] {
            // Emergency's row takes the device's sizes: the iPad's page measured on an iPad only.
            if layout == .wide && CockpitScale.current != .kneeboard { continue }
            let parts = try layOut(waypoints: 6, size: size, layout: layout)
            let emergency = try XCTUnwrap(parts[.emergency]).height + 4      // its row, and the foot's 4 pt
            let margin: CGFloat = layout == .wide ? 16 : 12                   // `AutoMarkUndoToast`'s
            let toast = UIHostingController(rootView: NavUndoToast(offer: offer, compact: layout != .wide) {}
                .environment(\.cockpitTheme, .day))
                .sizeThatFits(in: CGSize(width: size.width - 2 * margin, height: .greatestFiniteMagnitude)).height
            let reach = toast + 8 - emergency
            let clearance = RouteLegsAndRadio.toastClearance(layout)
            XCTAssertLessThanOrEqual(reach, clearance, "\(size.width) pt: the toast reaches \(reach) pt over the scroll")
            XCTAssertGreaterThan(reach, clearance - 16, "\(size.width) pt: no more room than it takes (\(reach) of \(clearance))")
        }
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

        _ = render(FlightView(initialPage: .checklist, radio: radio), services: services,
                   size: CGSize(width: 820, height: 1_180))

        XCTAssertGreaterThanOrEqual(radio.computations, 1, "computed with no map on screen")
        XCTAssertEqual(radio.now?.freq, "120.100")
        XCTAssertEqual(radio.next?.freq, "119.175")
        XCTAssertTrue(radio.stations.contains { $0.station == "Geneva Info" }, "\(radio.stations.map(\.station))")
        XCTAssertEqual(radio.emergency.map(\.freq), ["121.500"])
    }

    // MARK: - A leg's row

    /// Every waypoint's name whole at the phone's 17 pt, SAIGNELÉGIER's twelve letters too, on an iPhone
    /// SE, a 17e and a 17 (ROUTE's 16 pt each side). Beside PLAN, ACT and Δ the name had what the three
    /// columns left, about 30 pt on the 17e: "LS…", "SA…".
    func testEveryNameStaysWholeAtThePhonesSize() throws {
        for screen: CGFloat in [375, 390, 402] {
            let frames = layOutRows(Self.longNames, width: screen - 32, scale: .phone)
            for (index, name) in Self.longNames.enumerated() {
                let frame = try XCTUnwrap(frames[index]?[.name], "\(name) at \(screen) pt")
                let whole = Self.width(of: name, size: CockpitType.label(for: .phone))
                XCTAssertGreaterThanOrEqual(frame.width + 0.5, whole,
                                            "\(name) at \(screen) pt: \(frame.width) pt of the \(whole) it needs")
            }
        }
    }

    /// PLAN, ACT and Δ in one place on every row, whatever the name beside them: the columns never move
    /// with a value.
    func testTheFiguresKeepTheirColumnWhateverTheName() throws {
        for (width, scale) in [(CGFloat(375 - 32), CockpitScale.phone), (402 - 32, .phone), (440 - 32, .phone),
                               (464, .kneeboard)] {
            let frames = layOutRows(Self.longNames, width: width, scale: scale)
            let figures = try Self.longNames.indices.map { try XCTUnwrap(frames[$0]?[.figures]) }
            XCTAssertEqual(Set(figures.map(\.minX)).count, 1, "one column at \(width) pt: \(figures)")
            XCTAssertEqual(Set(figures.map(\.width)).count, 1, "one width at \(width) pt: \(figures)")
        }
    }

    /// A route's rows take its shape: on a phone, the figures under every name but the departure's, which
    /// has none (no leg arrives at it) and keeps one line, so the 17e's scroll of about 121 pt doesn't lose
    /// a row to an empty line; on the iPad's legs column, one line everywhere.
    func testTheDeparturesRowIsOneLineAndTheOthersTakeTheRoutesShape() throws {
        for screen: CGFloat in [375, 390, 402, 440] {
            let frames = layOutRows(Self.longNames, width: screen - 32, scale: .phone)
            let departure = try XCTUnwrap(frames[0]), first = try XCTUnwrap(frames[1])
            XCTAssertEqual(try XCTUnwrap(departure[.figures]).midY, try XCTUnwrap(departure[.name]).midY, accuracy: 2,
                           "the departure's row on one line at \(screen) pt")
            XCTAssertLessThan(try XCTUnwrap(departure[.row]).height + 10, try XCTUnwrap(first[.row]).height,
                              "the departure's row a line shorter at \(screen) pt")
            for index in Self.longNames.indices.dropFirst() {
                let row = try XCTUnwrap(frames[index])
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(row[.figures]).minY, try XCTUnwrap(row[.name]).maxY,
                                            "\(Self.longNames[index])'s figures under its name at \(screen) pt")
                XCTAssertEqual(try XCTUnwrap(row[.row]).height, try XCTUnwrap(first[.row]).height,
                               "\(Self.longNames[index])'s row as tall as the route's others at \(screen) pt")
            }
        }
        let iPad = layOutRows(Self.longNames, width: 464, scale: .kneeboard)
        for index in Self.longNames.indices {
            XCTAssertEqual(try XCTUnwrap(iPad[index]?[.row]).height, try XCTUnwrap(iPad[0]?[.row]).height,
                           "\(Self.longNames[index]): one line on the iPad, as the departure's")
        }
    }

    /// Plan › Map's DIRECT on a long name whose figures are under it: on their line, never over the name.
    /// Centred on the row as on a single line, it covered the end of SAIGNELÉGIER on a 17e.
    func testDirectNeverCoversTheNameOfATwoLineRow() throws {
        for screen: CGFloat in [375, 390, 402] {
            // SAIGNELÉGIER, the leg being flown, offered while diverting (where DIRECT rejoins the route).
            let frames = layOutRows(Self.longNames, width: screen - 32, scale: .phone, directAt: 1)
            let row = try XCTUnwrap(frames[1])
            let name = try XCTUnwrap(row[.name]), direct = try XCTUnwrap(row[.direct], "DIRECT at \(screen) pt")
            XCTAssertFalse(name.intersects(direct), "at \(screen) pt, name \(name), DIRECT \(direct)")
            XCTAssertGreaterThanOrEqual(direct.minY, name.maxY, "DIRECT under the name at \(screen) pt")
            XCTAssertLessThanOrEqual(direct.maxY, try XCTUnwrap(row[.row]).maxY + 9, "inside its row at \(screen) pt")
            XCTAssertGreaterThanOrEqual(name.width + 0.5, Self.width(of: Self.longNames[1], size: 17), "the name whole")
        }
        // The departure while diverting (DIRECT rejoins the route anywhere): DIRECT under its name too.
        let departure = try XCTUnwrap(layOutRows(Self.longNames, width: 390 - 32, scale: .phone, directAt: 0)[0])
        XCTAssertFalse(try XCTUnwrap(departure[.name]).intersects(try XCTUnwrap(departure[.direct])))
    }

    /// The iPad's legs column beside the radio (464 pt in portrait): a row on one line, as before, every
    /// name whole at the 80 % it may shrink to.
    func testTheIPadKeepsItsRowsOnOneLine() throws {
        let frames = layOutRows(Self.longNames, width: 464, scale: .kneeboard)
        for (index, name) in Self.longNames.enumerated() {
            let nameFrame = try XCTUnwrap(frames[index]?[.name]), figures = try XCTUnwrap(frames[index]?[.figures])
            XCTAssertEqual(nameFrame.midY, figures.midY, accuracy: 2, "\(name): the figures beside the name")
            XCTAssertGreaterThanOrEqual(nameFrame.width + 0.5,
                                        Self.width(of: name, size: CockpitType.label(for: .kneeboard)) * 0.8, name)
        }
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
        // A phone (6.2): nothing over the chart's top since the read band, the bar and the scale at its
        // foot. The foot takes what the top leaves, and the leg keeps a third of the chart.
        let phone = LegFraming.edgePadding(chartSize: CGSize(width: 390, height: 300), topChrome: 8, bottomChrome: 160)
        XCTAssertEqual(phone.top, 24)
        XCTAssertEqual(phone.bottom, 176, "the whole bar and scale")
        XCTAssertEqual(300 - phone.top - phone.bottom, 100, accuracy: 0.001)
        // A phone with BRIEFING over the chart's top: the foot gives way, never under a fifth for the leg.
        let crowded = LegFraming.edgePadding(chartSize: CGSize(width: 390, height: 260), topChrome: 70, bottomChrome: 160)
        XCTAssertEqual(260 - crowded.top - crowded.bottom, 52, accuracy: 0.001)
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

    /// Grenchen, SAIGNELÉGIER, ST-URSANNE, Bressaucourt: the longest name a Jura route has.
    private static let longNames = ["LSZG", "SAIGNELÉGIER", "ST-URSANNE", "LSZQ"]

    /// `names` as a route's leg rows, the second one flown to, `width` wide at `scale`: each row's name
    /// and figures as laid out.
    private func layOutRows(_ names: [String], width: CGFloat, scale: CockpitScale,
                            directAt: Int? = nil) -> [Int: [LegRowPart: CGRect]] {
        var plan = FlightPlan(name: "Leg rows", waypoints: names.enumerated().map { index, name in
            FlightPlanWaypoint(name: name, coordinate: .init(latitude: 47.4 - Double(index) * 0.1, longitude: 7.0),
                               estimatedElapsedTime: 600)
        })
        plan.currentWaypointIndex = 1
        final class Box { var frames: [Int: [LegRowPart: CGRect]] = [:] }
        let box = Box()
        let rows = VStack(spacing: 0) {
            ForEach(names.indices, id: \.self) { index in
                // DIRECT as Plan › Map offers it on a previewed row.
                RouteLegRow(plan: plan, index: index, actual: index == 1 ? 105 : nil, scale: scale,
                            reservesDirect: index == directAt, onTap: {})
                    .modifier(LegRowDirect(index: index, large: true, action: index == directAt ? {} : nil))
            }
        }
        .frame(width: width)
        .coordinateSpace(name: RouteLegRow.space)
        .environment(\.legRowReporter, { index, part, frame in box.frames[index, default: [:]][part] = frame })
        .environment(\.cockpitTheme, CockpitTheme.resolve(.day))
        _ = ImageRenderer(content: rows).uiImage
        return box.frames
    }

    /// `text` set in B612 Mono at `size`, as the rows set a name.
    private static func width(of text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: UIFont.aero(size: size, weight: .bold, monospaced: true)]).width
    }

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
