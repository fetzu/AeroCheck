import XCTest
import CoreLocation
@testable import AeroCheck

/// Divert from the Companion iPhone (6.2.0): the phone's list and its request, and the iPad applying a
/// field from the phone through its own Divert sheet's entry points. The wire contract is in
/// `CompanionServiceContractTests`, the Allow gate in `CompanionPeerAuthorizationTests`.
final class CompanionDivertTests: XCTestCase {

    private let here = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)

    /// A field `nm` nautical miles due east of `here` (one minute of longitude is cos(lat) NM).
    private func field(_ ident: String, east nm: Double, name: String? = nil) -> TripPlanner.Aerodrome {
        let longitude = 7.0 + nm / (60 * cos(47.0 * .pi / 180))
        return TripPlanner.Aerodrome(ident: ident, name: name ?? "Field \(ident)", latitude: 47.0,
                                     longitude: longitude, elevationFeet: 1_400, frequency: "AFIS 120.155",
                                     isPPR: false)
    }

    // MARK: - The phone's nearest list

    func testTheNearestFieldsComeFirst() {
        let list = [field("LSZC", east: 30), field("LSZA", east: 4), field("LSZB", east: 12)]
        let rows = CompanionDivert.nearest(from: here, aerodromes: list, destinationIdent: nil, lastWaypointName: nil)
        XCTAssertEqual(rows.map(\.aerodrome.ident), ["LSZA", "LSZB", "LSZC"])
        XCTAssertEqual(rows[0].distanceNM ?? 0, 4, accuracy: 0.05)
        XCTAssertEqual(rows[0].bearing ?? 0, 90, accuracy: 0.5, "due east, true")
    }

    func testTheNearestListStopsAtTheRangeAndTheLimit() {
        let far = field("LFXX", east: CompanionDivert.rangeNM + 1)
        let near = (1...12).map { field(String(format: "LS%02d", $0), east: Double($0)) }
        let rows = CompanionDivert.nearest(from: here, aerodromes: near + [far], destinationIdent: nil,
                                           lastWaypointName: nil)
        XCTAssertEqual(rows.count, CompanionDivert.maxNearest)
        XCTAssertFalse(rows.contains { $0.aerodrome.ident == "LFXX" }, "beyond the iPad sheet's range")
        XCTAssertEqual(CompanionDivert.nearest(from: here, aerodromes: [far], destinationIdent: nil,
                                               lastWaypointName: nil), [])
    }

    func testEqualDistancesGoByIdentAndAFieldListedTwiceCountsOnce() {
        let list = [field("LSZB", east: 5), field("LSZA", east: 5), field("lsza", east: 5)]
        let rows = CompanionDivert.nearest(from: here, aerodromes: list, destinationIdent: nil, lastWaypointName: nil)
        XCTAssertEqual(rows.map(\.aerodrome.ident), ["LSZA", "LSZB"], "the order never flickers")
    }

    func testTheRoutesDestinationIsMarked() {
        let list = [field("LSGC", east: 8), field("LSZQ", east: 3)]
        let rows = CompanionDivert.nearest(from: here, aerodromes: list, destinationIdent: "LSGC",
                                           lastWaypointName: "Les Eplatures")
        XCTAssertEqual(rows.first { $0.aerodrome.ident == "LSGC" }?.isDestination, true)
        XCTAssertEqual(rows.first { $0.aerodrome.ident == "LSZQ" }?.isDestination, false)
    }

    func testRowsKeepTheirOrderAndHaveNoFiguresWithoutAPosition() {
        let list = [field("LSZC", east: 30), field("LSZA", east: 4)]
        let shown = CompanionDivert.rows(list, from: here, destinationIdent: nil, lastWaypointName: nil)
        XCTAssertEqual(shown.map(\.aerodrome.ident), ["LSZC", "LSZA"], "a search's order, or the order shown")
        let blind = CompanionDivert.rows(list, from: nil, destinationIdent: nil, lastWaypointName: nil)
        XCTAssertEqual(blind.map(\.aerodrome.ident), ["LSZC", "LSZA"])
        XCTAssertTrue(blind.allSatisfy { $0.bearing == nil && $0.distanceNM == nil })
    }

    /// The aircraft's position as the iPad streams it, else this phone's own recent fix, else none.
    func testTheListIsMeasuredFromTheStreamThenThePhonesOwnFix() {
        let now = Date()
        let own = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 46.5, longitude: 6.5), altitude: 500,
                             horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-3))
        let streamed = CompanionDivert.reference(streamedLatitude: 47.1, streamedLongitude: 7.2, ownFix: own, now: now)
        XCTAssertEqual(streamed?.latitude, 47.1)
        XCTAssertEqual(streamed?.longitude, 7.2)

        let fallback = CompanionDivert.reference(streamedLatitude: nil, streamedLongitude: nil, ownFix: own, now: now)
        XCTAssertEqual(fallback?.latitude, 46.5)
        let halfStream = CompanionDivert.reference(streamedLatitude: 47.1, streamedLongitude: nil, ownFix: own, now: now)
        XCTAssertEqual(halfStream?.latitude, 46.5, "half a coordinate is no position")

        let stale = CLLocation(coordinate: own.coordinate, altitude: 500, horizontalAccuracy: 5, verticalAccuracy: 5,
                               timestamp: now.addingTimeInterval(-(CompanionDivert.ownFixMaxAge + 1)))
        XCTAssertNil(CompanionDivert.reference(streamedLatitude: nil, streamedLongitude: nil, ownFix: stale, now: now))
        let invalid = CLLocation(coordinate: own.coordinate, altitude: 500, horizontalAccuracy: -1,
                                 verticalAccuracy: 5, timestamp: now)
        XCTAssertNil(CompanionDivert.reference(streamedLatitude: nil, streamedLongitude: nil, ownFix: invalid, now: now))
    }

    func testTheDestinationRule() {
        XCTAssertTrue(CompanionDivert.isDestination("LSGC", destinationIdent: "LSGC", lastWaypointName: "Home"))
        XCTAssertTrue(CompanionDivert.isDestination("lsgc", destinationIdent: "LSGC", lastWaypointName: nil))
        XCTAssertFalse(CompanionDivert.isDestination("LSGC", destinationIdent: "LSZQ", lastWaypointName: "LSGC"),
                       "the airport data's answer wins over the name")
        XCTAssertTrue(CompanionDivert.isDestination("LSGC", destinationIdent: nil, lastWaypointName: "LSGC"),
                      "without one, the last waypoint named after the field")
        XCTAssertFalse(CompanionDivert.isDestination("LSGC", destinationIdent: nil, lastWaypointName: "Lake"))
        XCTAssertFalse(CompanionDivert.isDestination("", destinationIdent: nil, lastWaypointName: ""))
    }

    // MARK: - The request, until the iPad shows it taken

    private func snapshot(diversion ident: String? = nil, index: Int = 1, count: Int = 3) -> CompanionFlightPlanSnapshot {
        let waypoints = (0..<count).map { i in
            CompanionWaypoint(id: UUID(), name: "W\(i)", latitude: 47, longitude: 7 + Double(i) / 10, altitude: nil,
                              frequency: nil, magneticCourse: nil, distance: nil, plannedGroundSpeed: nil,
                              estimatedElapsedTime: nil, legEETExtra: nil, cumulativeEET: nil,
                              estimatedTimeOver: nil, actualTimeOver: nil, remarks: "")
        }
        let diversion = ident.map {
            CompanionWaypoint(id: UUID(), name: $0, latitude: 46.9, longitude: 7.3, altitude: nil, frequency: nil,
                              magneticCourse: nil, distance: nil, plannedGroundSpeed: nil, estimatedElapsedTime: nil,
                              legEETExtra: nil, cumulativeEET: nil, estimatedTimeOver: nil, actualTimeOver: nil,
                              remarks: "Field")
        }
        return CompanionFlightPlanSnapshot(planId: UUID(), planName: "P", waypoints: waypoints,
                                           currentWaypointIndex: index, totalDistance: 0, totalEET: 0,
                                           plannedDepartureTime: nil, chronometerStartTime: nil,
                                           diversion: diversion, supportsDivert: true)
    }

    func testARequestIsSentAgainUntilTheIPadShowsIt() {
        let t0 = Date()
        let command = CompanionCommand.divert(field: CompanionDivert.field(field("LSZB", east: 5)))
        var request = CompanionDivert.Request(goal: .divert(ident: "LSZB"), command: command, sentAt: t0)
        let notYet = snapshot()

        XCTAssertEqual(request.step(now: t0.addingTimeInterval(1), plan: notYet), .wait)
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(2), plan: notYet), .resend)
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(3), plan: notYet), .wait, "every two seconds")
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(4), plan: notYet), .resend)
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(5), plan: nil), .wait, "no plan yet: nothing taken")
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(5), plan: snapshot(diversion: "lszb")), .taken)
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(5), plan: snapshot(diversion: "LSZE")), .wait,
                       "another diversion is not this one")
    }

    func testARequestNotTakenIsGivenUpThenStillSeenTakenLate() {
        let t0 = Date()
        var request = CompanionDivert.Request(goal: .resume, command: .resumeRoute, sentAt: t0)
        let diverting = snapshot(diversion: "LSZB")
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(CompanionDivert.Request.giveUpAfter), plan: diverting),
                       .gaveUp)
        XCTAssertTrue(request.gaveUp)
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(40), plan: diverting), .wait, "sent no more")
        XCTAssertEqual(request.step(now: t0.addingTimeInterval(45), plan: snapshot()), .taken)
    }

    func testDirectToTheDestinationIsTakenOnceOnTheLastLegUndiverted() {
        let request = CompanionDivert.Request(goal: .destination, command: .resumeRoute, sentAt: Date())
        XCTAssertFalse(request.isTaken(by: snapshot(index: 1)))
        XCTAssertFalse(request.isTaken(by: snapshot(diversion: "LSZB", index: 2)))
        XCTAssertTrue(request.isTaken(by: snapshot(index: 2)))
    }

    // MARK: - The iPad's decision

    private func route() -> FlightPlan {
        var plan = FlightPlan(name: "Divert", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)),
            FlightPlanWaypoint(name: "W1", coordinate: CLLocationCoordinate2D(latitude: 47.0, longitude: 7.3)),
            FlightPlanWaypoint(name: "LSGC", coordinate: CLLocationCoordinate2D(latitude: 47.08, longitude: 6.79)),
        ])
        plan.currentWaypointIndex = 1
        return plan
    }

    private func wire(_ ident: String, name: String = "Field", latitude: Double = 46.95, longitude: Double = 7.4,
                      frequency: String? = "INFO 125.000") -> CompanionDivertField {
        CompanionDivertField(ident: ident, name: name, latitude: latitude, longitude: longitude, elevationFeet: 1_500,
                             frequency: frequency)
    }

    func testAFieldFromThePhoneIsADiversion() {
        let action = CompanionDivert.action(for: wire("LSZB"), plan: route(), own: nil, destinationIdent: "LSGC")
        guard case .divert(let aerodrome) = action else { return XCTFail("\(action)") }
        XCTAssertEqual(aerodrome.ident, "LSZB")
        XCTAssertEqual(aerodrome.latitude, 46.95)
        XCTAssertEqual(aerodrome.frequency, "INFO 125.000")
        XCTAssertEqual(aerodrome.elevationFeet, 1_500)
    }

    /// The iPad's own record of the ident first; what it lacks, from the phone's.
    func testTheIPadsOwnRecordWins() {
        let own = TripPlanner.Aerodrome(ident: "LSZB", name: "Bern-Belp", latitude: 46.9141, longitude: 7.4971,
                                        elevationFeet: nil, frequency: nil, isPPR: true, country: "CH")
        let action = CompanionDivert.action(for: wire("LSZB", name: "Old name"), plan: route(), own: own,
                                            destinationIdent: "LSGC")
        guard case .divert(let aerodrome) = action else { return XCTFail("\(action)") }
        XCTAssertEqual(aerodrome.name, "Bern-Belp")
        XCTAssertEqual(aerodrome.latitude, 46.9141)
        XCTAssertEqual(aerodrome.longitude, 7.4971)
        XCTAssertEqual(aerodrome.elevationFeet, 1_500, "the gap filled from the phone")
        XCTAssertEqual(aerodrome.frequency, "INFO 125.000")
        XCTAssertTrue(aerodrome.isPPR)
    }

    func testTheRoutesDestinationIsDirectTo() {
        let plan = route()
        XCTAssertEqual(CompanionDivert.action(for: wire("LSGC"), plan: plan, own: nil, destinationIdent: "LSGC"),
                       .directTo(index: 2))
        XCTAssertEqual(CompanionDivert.action(for: wire("LSGC"), plan: plan, own: nil, destinationIdent: nil),
                       .directTo(index: 2), "named after the field, without airport data")
        var diverted = plan
        diverted.currentWaypointIndex = 2
        diverted.diversion = Diversion(ident: "LSZB", name: "Bern", latitude: 46.9, longitude: 7.5, elevationFeet: nil,
                                       frequency: nil, startedAt: Date(), leftRouteAt: 2)
        XCTAssertEqual(CompanionDivert.action(for: wire("LSGC"), plan: diverted, own: nil, destinationIdent: "LSGC"),
                       .directTo(index: 2), "ends the diversion, as the iPad's sheet does")
    }

    /// Sent again until the phone sees it: where the aircraft already goes, nothing changes (the leg
    /// timer and the diversion's start time stay).
    func testWhereTheAircraftAlreadyGoesChangesNothing() {
        var plan = route()
        plan.diversion = Diversion(ident: "LSZB", name: "Bern", latitude: 46.9, longitude: 7.5, elevationFeet: nil,
                                   frequency: nil, startedAt: Date(), leftRouteAt: 1)
        XCTAssertEqual(CompanionDivert.action(for: wire("lszb"), plan: plan, own: nil, destinationIdent: "LSGC"), .none)
        var lastLeg = route()
        lastLeg.currentWaypointIndex = 2
        XCTAssertEqual(CompanionDivert.action(for: wire("LSGC"), plan: lastLeg, own: nil, destinationIdent: "LSGC"), .none)
    }

    func testAFieldWithNoIdentOrPositionIsNotTaken() {
        XCTAssertEqual(CompanionDivert.action(for: wire(""), plan: route(), own: nil, destinationIdent: nil), .none)
        XCTAssertEqual(CompanionDivert.action(for: wire("LSZB", latitude: .nan), plan: route(), own: nil,
                                              destinationIdent: nil), .none)
        XCTAssertEqual(CompanionDivert.action(for: wire("LSZB", latitude: 91), plan: route(), own: nil,
                                              destinationIdent: nil), .none)
        XCTAssertEqual(CompanionDivert.action(for: wire("LSZB"), plan: FlightPlan(name: "Empty"), own: nil,
                                              destinationIdent: nil), .none)
    }

    // MARK: - The iPad applying it

    private struct Master {
        let appState: AppState
        let plans: FlightPlanManager
    }

    /// An iPad in flight on `route()`, W1 next, its leg timer running for ten minutes.
    @MainActor
    private func masterInFlight(flying: Bool = true) throws -> Master {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        if flying {
            appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
            addTeardownBlock { @MainActor in appState.cancelFlight() }
        }
        let plans = makeTestPlanManager()
        plans.activateFlightPlan(route())
        try XCTSkipIf(plans.activeFlightPlan == nil, "no active plan")
        plans.advanceToNextWaypoint()
        plans.restoreLegTimer(.init(accumulated: 300, startTime: Date().addingTimeInterval(-300)))
        return Master(appState: appState, plans: plans)
    }

    /// The phone's Divert is the iPad's own: the same diversion its sheet's `divert(to:)` makes, the nav
    /// target on the field, the leg timer started afresh.
    @MainActor
    func testTheIPadDivertsThroughItsOwnEntryPoint() throws {
        let master = try masterInFlight()
        let sent = wire("LSZB", name: "Bern-Belp", latitude: 46.9141, longitude: 7.4971)
        let before = Date()
        CompanionConnectivityManager.apply(.divert(field: sent), appState: master.appState,
                                           flightPlanManager: master.plans)

        let plan = try XCTUnwrap(master.plans.activeFlightPlan)
        let diversion = try XCTUnwrap(plan.diversion, "diverting")
        XCTAssertEqual(diversion.ident, "LSZB")
        XCTAssertEqual(diversion.name, "Bern-Belp")
        XCTAssertEqual(diversion.latitude, 46.9141)
        XCTAssertEqual(diversion.longitude, 7.4971)
        XCTAssertEqual(diversion.elevationFeet, 1_500)
        XCTAssertEqual(diversion.frequency, "INFO 125.000")
        XCTAssertEqual(diversion.leftRouteAt, 1, "left the route at the waypoint that was next")
        XCTAssertGreaterThanOrEqual(diversion.startedAt ?? .distantPast, before.addingTimeInterval(-1))
        XCTAssertEqual(plan.navigationTarget, NavigationTarget(name: "LSZB", latitude: 46.9141, longitude: 7.4971,
                                                               frequency: "INFO 125.000", isDiversion: true))
        XCTAssertEqual(master.plans.activeNextWaypointName, "LSZB", "the Live Activity follows")
        XCTAssertEqual(plan.currentWaypointIndex, 1, "the route stays as planned")
        let timer = try XCTUnwrap(master.plans.legTimerSnapshot)
        XCTAssertEqual(timer.accumulated, 0, "the leg timer starts afresh, as the sheet's divert does")
        XCTAssertGreaterThanOrEqual(timer.startTime ?? .distantPast, before.addingTimeInterval(-1))

        // The same field from the iPad's own sheet gives the same diversion.
        let reference = try masterInFlight()
        reference.plans.divert(to: CompanionDivert.aerodrome(sent, own: nil))
        var expected = try XCTUnwrap(reference.plans.activeFlightPlan?.diversion)
        expected.startedAt = diversion.startedAt
        XCTAssertEqual(diversion, expected)
    }

    @MainActor
    func testAFieldSentAgainKeepsTheDiversionAsItWas() throws {
        let master = try masterInFlight()
        CompanionConnectivityManager.apply(.divert(field: wire("LSZB")), appState: master.appState,
                                           flightPlanManager: master.plans)
        let first = try XCTUnwrap(master.plans.activeFlightPlan?.diversion)
        master.plans.restoreLegTimer(.init(accumulated: 42, startTime: Date().addingTimeInterval(-60)))
        let timer = master.plans.legTimerSnapshot

        CompanionConnectivityManager.apply(.divert(field: wire("LSZB")), appState: master.appState,
                                           flightPlanManager: master.plans)
        XCTAssertEqual(master.plans.activeFlightPlan?.diversion, first)
        XCTAssertEqual(master.plans.legTimerSnapshot, timer, "the leg timer runs on")
    }

    @MainActor
    func testResumeRouteFromThePhone() throws {
        let master = try masterInFlight()
        CompanionConnectivityManager.apply(.divert(field: wire("LSZB")), appState: master.appState,
                                           flightPlanManager: master.plans)
        XCTAssertNotNil(master.plans.activeFlightPlan?.diversion)

        CompanionConnectivityManager.apply(.resumeRoute, appState: master.appState, flightPlanManager: master.plans)
        let plan = try XCTUnwrap(master.plans.activeFlightPlan)
        XCTAssertNil(plan.diversion)
        XCTAssertEqual(plan.navigationTarget?.name, "W1", "back at the waypoint that was next")
    }

    @MainActor
    func testTheDestinationFromThePhoneIsDirectTo() throws {
        let master = try masterInFlight()
        CompanionConnectivityManager.apply(.divert(field: wire("LSGC", latitude: 47.08, longitude: 6.79)),
                                           appState: master.appState, flightPlanManager: master.plans)
        let plan = try XCTUnwrap(master.plans.activeFlightPlan)
        XCTAssertNil(plan.diversion, "direct to, not a diversion")
        XCTAssertEqual(plan.currentWaypointIndex, 2)
    }

    /// On the ground (the flight ended, the phone's screen a little behind), an armed plan gets no
    /// diversion.
    @MainActor
    func testNothingHappensOutsideAFlight() throws {
        let master = try masterInFlight(flying: false)
        CompanionConnectivityManager.apply(.divert(field: wire("LSZB")), appState: master.appState,
                                           flightPlanManager: master.plans)
        XCTAssertNil(master.plans.activeFlightPlan?.diversion)
        CompanionConnectivityManager.apply(.divert(field: wire("LSZB")), appState: nil, flightPlanManager: master.plans)
        XCTAssertNil(master.plans.activeFlightPlan?.diversion)
    }

    /// The iPad's own airport record of the ident, when it has one.
    @MainActor
    func testTheIPadUsesItsOwnAirportRecord() throws {
        let master = try masterInFlight()
        let airports = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
        airports.injectForReplay([
            Airport(id: 1, ident: "LSZB", type: .mediumAirport, name: "Bern-Belp", latitude: 46.9141,
                    longitude: 7.4971, elevation: 1_674, continent: "EU", isoCountry: "CH", isoRegion: "CH-BE",
                    municipality: "Bern", scheduledService: true, gpsCode: "LSZB", iataCode: "BRN", localCode: nil),
            Airport(id: 2, ident: "LSGC", type: .smallAirport, name: "Les Eplatures", latitude: 47.0839,
                    longitude: 6.7928, elevation: 3_368, continent: "EU", isoCountry: "CH", isoRegion: "CH-NE",
                    municipality: "La Chaux-de-Fonds", scheduledService: false, gpsCode: "LSGC", iataCode: nil,
                    localCode: nil),
        ])
        CompanionConnectivityManager.apply(.divert(field: wire("LSZB", name: "Phone's name", latitude: 46.9,
                                                               longitude: 7.5, frequency: nil)),
                                           appState: master.appState, flightPlanManager: master.plans,
                                           airports: airports)
        let diversion = try XCTUnwrap(master.plans.activeFlightPlan?.diversion)
        XCTAssertEqual(diversion.name, "Bern-Belp")
        XCTAssertEqual(diversion.latitude, 46.9141)
        XCTAssertEqual(diversion.elevationFeet, 1_674)
        XCTAssertEqual(airports.routeDestinationIdent(name: "Somewhere", coordinate: CLLocationCoordinate2D(
            latitude: 47.0839, longitude: 6.7928)), "LSGC", "a destination not named after its field")
    }
}
