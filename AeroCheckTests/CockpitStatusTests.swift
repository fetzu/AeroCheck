import XCTest
import CoreLocation
import MapKit
@testable import AeroCheck

/// The MAP page's status slot and the chart's chrome rules (6.2.0): the slot's priority and each
/// state's inputs, OFF ROUTE with its hysteresis and its suppressions, CHART OFFLINE, the edge arrow
/// and the scale's two seconds.
final class CockpitStatusTests: XCTestCase {

    // MARK: - Priority

    private var everything: CockpitStatusRule.Inputs {
        CockpitStatusRule.Inputs(undoOffered: true, gps: .lost, offRouteNM: 1.4, chartOffline: true,
                                 tellFISField: "LSGC", sigmetOnPath: "TS", briefing: .approach)
    }

    /// UNDO > NO GPS > OFF ROUTE > CHART OFFLINE > TELL FIS > SIGMET > BRIEFING > GPS DEGRADED, one at a time.
    func testTheSlotShowsTheHighestStatePending() {
        XCTAssertEqual(CockpitStatusRule.pending(everything), [
            .undo, .gps(.lost), .offRoute(crossTrackNM: 1.4), .chartOffline, .tellFIS(field: "LSGC"),
            .sigmet(summary: "TS"), .briefing(.approach),
        ])

        var inputs = everything
        XCTAssertEqual(CockpitStatusRule.current(inputs), .undo, "the pilot's own tap first, for its six seconds")
        inputs.undoOffered = false
        XCTAssertEqual(CockpitStatusRule.current(inputs), .gps(.lost))
        inputs.gps = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .offRoute(crossTrackNM: 1.4))
        inputs.offRouteNM = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .chartOffline)
        inputs.chartOffline = false
        XCTAssertEqual(CockpitStatusRule.current(inputs), .tellFIS(field: "LSGC"))
        inputs.tellFISField = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .sigmet(summary: "TS"))
        inputs.sigmetOnPath = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .briefing(.approach))
        inputs.briefing = nil
        XCTAssertNil(CockpitStatusRule.current(inputs), "a dark slot")
    }

    /// GPS DEGRADED waits behind everything else (on the ground it held the slot over CHART OFFLINE and
    /// BRIEFING; the header and the strip show it); NO GPS keeps its place under UNDO. (5 Oct, device check)
    func testGPSDegradedComesLastAndNoGPSStaysHigh() {
        var inputs = everything
        inputs.undoOffered = false
        inputs.gps = .degraded
        XCTAssertEqual(CockpitStatusRule.pending(inputs), [
            .offRoute(crossTrackNM: 1.4), .chartOffline, .tellFIS(field: "LSGC"), .sigmet(summary: "TS"),
            .briefing(.approach), .gps(.degraded),
        ])
        XCTAssertEqual(CockpitStatusRule.current(CockpitStatusRule.Inputs(gps: .degraded, chartOffline: true)), .chartOffline,
                       "airplane mode on the ground: CHART OFFLINE")
        XCTAssertEqual(CockpitStatusRule.current(CockpitStatusRule.Inputs(gps: .degraded, briefing: .approach)),
                       .briefing(.approach), "the descent: BRIEFING")
        XCTAssertEqual(CockpitStatusRule.current(CockpitStatusRule.Inputs(gps: .degraded)), .gps(.degraded),
                       "alone, it shows")
        XCTAssertEqual(CockpitStatusRule.current(CockpitStatusRule.Inputs(gps: .lost, briefing: .approach)), .gps(.lost))
    }

    /// The others wait: once UNDO's window is over, what was pending shows.
    func testWhenUndoEndsTheWaitingStateShows() {
        var inputs = CockpitStatusRule.Inputs(undoOffered: true, briefing: .departure)
        XCTAssertEqual(CockpitStatusRule.current(inputs), .undo)
        inputs.undoOffered = false
        XCTAssertEqual(CockpitStatusRule.current(inputs), .briefing(.departure))
    }

    func testEachStateHasItsToneAndIdentifier() {
        let expected: [(CockpitStatus, CockpitStatus.Tone, String)] = [
            (.undo, .neutral, "status.undo"),
            (.gps(.degraded), .caution, "status.gps"),
            (.gps(.lost), .warning, "status.gps"),
            (.offRoute(crossTrackNM: 1.2), .caution, "status.offRoute"),
            (.chartOffline, .caution, "status.chartOffline"),
            (.tellFIS(field: "LSGC"), .caution, "status.tellFIS"),
            (.sigmet(summary: "TS"), .caution, "status.sigmet"),
            (.briefing(.departure), .action, "status.briefing"),
        ]
        for (state, tone, identifier) in expected {
            XCTAssertEqual(state.tone, tone, "\(state)")
            XCTAssertEqual(state.accessibilityIdentifier, identifier, "\(state)")
        }
    }

    // MARK: - Each state's inputs

    /// The header's rule: a flight not recording is NO GPS whatever the signal; nothing while simulating.
    func testGPSFollowsTheHeadersRule() {
        func alarm(_ active: Bool, _ tracking: Bool, _ signal: GPSSignalStatus,
                   simulating: Bool = false) -> CockpitStatus.GPSAlarm? {
            CockpitStatusRule.gpsAlarm(isFlightActive: active, isTracking: tracking, signal: signal,
                                       isSimulating: simulating)
        }
        XCTAssertNil(alarm(true, true, .good))
        XCTAssertEqual(alarm(true, true, .degraded), .degraded)
        XCTAssertEqual(alarm(true, true, .lost), .lost)
        XCTAssertEqual(alarm(true, false, .good), .lost, "an active flight not recording loses its track")
        XCTAssertNil(alarm(false, false, .lost), "no flight, no recording: dim in the header, nothing here")
        XCTAssertNil(alarm(true, true, .degraded, simulating: true), "GPS · SIM is held at degraded on purpose")
        XCTAssertNil(alarm(true, false, .lost, simulating: true))
    }

    func testTellFISOnlyWithAnOpenATCFlightPlan() {
        XCTAssertEqual(CockpitStatusRule.tellFIS(diversionIdent: "LSGC", hasOpenATCFlightPlan: true), "LSGC")
        XCTAssertNil(CockpitStatusRule.tellFIS(diversionIdent: "LSGC", hasOpenATCFlightPlan: false))
        XCTAssertNil(CockpitStatusRule.tellFIS(diversionIdent: nil, hasOpenATCFlightPlan: true))
    }

    private func hazard(_ name: String, inside: Bool = false, crossesRoute: Bool = false,
                        distance: Double = 40) -> SigmetHazardItem {
        SigmetHazardItem(
            sigmet: AviationWeatherService.Sigmet(firId: "LSAS", firName: nil, hazard: name, qualifier: nil,
                                                  baseFt: nil, topFt: nil, validFrom: nil, validTo: nil,
                                                  distanceNm: distance, containsPoint: inside, coords: [], raw: nil),
            assessment: SigmetRelevance.Assessment(distanceNm: distance, containsAircraft: inside,
                                                   intersectsRoute: crossesRoute, routeDistanceNm: nil))
    }

    /// Only a SIGMET on the aircraft's path takes the slot; the others go to More.
    func testOnlyASigmetOnThePathTakesTheSlot() {
        let offPath = hazard("ICE", distance: 12)
        XCTAssertNil(CockpitStatusRule.sigmetOnPath([offPath]))
        XCTAssertNil(CockpitStatusRule.sigmetOnPath([]))
        let across = hazard("TURB", crossesRoute: true)
        let inside = hazard("TS", inside: true, distance: 0)
        XCTAssertEqual(CockpitStatusRule.sigmetOnPath([offPath, across])?.sigmet.hazard, "TURB")
        XCTAssertEqual(CockpitStatusRule.sigmetOnPath([inside, across])?.sigmet.hazard, "TS",
                       "the first of the ranked list on the path")
    }

    func testBriefingIsThePhasesBriefing() {
        XCTAssertEqual(ChecklistPhase.beforeDeparture.briefingType, .departure)
        XCTAssertEqual(ChecklistPhase.descent.briefingType, .approach)
        XCTAssertNil(ChecklistPhase.cruise.briefingType)
        let inputs = CockpitStatusRule.Inputs(briefing: ChecklistPhase.descent.briefingType)
        XCTAssertEqual(CockpitStatusRule.current(inputs), .briefing(.approach))
    }

    // MARK: - OFF ROUTE

    /// An east-west leg along 46.5°N, 7.0°E to 7.5°E. A sixtieth of a degree of latitude is a mile.
    private let leg = OffRouteRule.Leg(from: .init(latitude: 46.5, longitude: 7.0),
                                       to: .init(latitude: 46.5, longitude: 7.5))

    private func abeam(_ nm: Double, longitude: Double = 7.25) -> CLLocationCoordinate2D {
        .init(latitude: 46.5 + nm / 60, longitude: longitude)
    }

    private func flying(_ nm: Double) -> OffRouteRule.Input {
        OffRouteRule.Input(leg: leg, aircraft: abeam(nm), airborne: true, gpsGood: true)
    }

    func testCrossTrackIsTheDistanceFromTheLeg() {
        XCTAssertEqual(OffRouteRule.crossTrackNM(abeam(1.2), leg: leg), 1.2, accuracy: 1e-9)
        XCTAssertEqual(OffRouteRule.crossTrackNM(abeam(-0.4), leg: leg), 0.4, accuracy: 1e-9)
        XCTAssertEqual(OffRouteRule.crossTrackNM(abeam(0), leg: leg), 0, accuracy: 1e-9)
    }

    /// Past either end of the leg, the distance is to that end.
    func testPastEitherEndTheDistanceIsToThatEnd() {
        // A mile of longitude at the aircraft's latitude, as the route search's flat projection takes it.
        func degreesEast(_ nm: Double, atLatitude latitude: Double) -> Double {
            nm / (60 * cos(latitude * .pi / 180))
        }
        let beyond = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.5 + degreesEast(2, atLatitude: 46.5))
        XCTAssertEqual(OffRouteRule.crossTrackNM(beyond, leg: leg), 2, accuracy: 1e-9)
        let latitude = 46.5 + 1.5 / 60
        let before = CLLocationCoordinate2D(latitude: latitude,
                                            longitude: 7.0 - degreesEast(2, atLatitude: latitude))
        XCTAssertEqual(OffRouteRule.crossTrackNM(before, leg: leg), 2.5, accuracy: 1e-9)
    }

    /// On above 1.0 NM, off below 0.7 NM; in between it stays as it was.
    func testOffRouteHasHysteresis() {
        var rule = OffRouteRule()
        XCTAssertNil(rule.update(flying(0.5)))
        XCTAssertNil(rule.update(flying(0.95)))
        XCTAssertNil(rule.update(flying(0.99)))
        XCTAssertEqual(try XCTUnwrap(rule.update(flying(1.05))), 1.05, accuracy: 1e-9)
        XCTAssertTrue(rule.isOffRoute)
        XCTAssertEqual(try XCTUnwrap(rule.update(flying(0.8))), 0.8, accuracy: 1e-9, "still off until below 0.7")
        XCTAssertNotNil(rule.update(flying(0.71)))
        XCTAssertNil(rule.update(flying(0.69)))
        XCTAssertFalse(rule.isOffRoute)
        XCTAssertNil(rule.update(flying(0.9)), "back under 1.0: on route again")
        XCTAssertNotNil(rule.update(flying(-1.3)), "either side of the leg")
    }

    func testTheHysteresisAsAPureFunction() {
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: 0.85, wasOffRoute: false))
        XCTAssertTrue(OffRouteRule.isOffRoute(crossTrackNM: 0.85, wasOffRoute: true))
        XCTAssertTrue(OffRouteRule.isOffRoute(crossTrackNM: 1.01, wasOffRoute: false))
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: 0.6, wasOffRoute: true))
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: 1.0, wasOffRoute: false), "above 1.0, not at it")
        XCTAssertTrue(OffRouteRule.isOffRoute(crossTrackNM: 0.7, wasOffRoute: true), "below 0.7, not at it")
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: .nan, wasOffRoute: true))
    }

    /// Dark without good GPS, diverting, in circuits, on the ground, with no fix or no leg.
    func testOffRouteIsSuppressedUnlessEveryConditionHolds() {
        let far = flying(3)
        XCTAssertNotNil(OffRouteRule.evaluate(far, wasOffRoute: false))
        var input = far
        input.gpsGood = false
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "GPS not good: the two never contradict")
        input = far
        input.diverting = true
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "diverting")
        input = far
        input.inCircuits = true
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "in circuits")
        input = far
        input.airborne = false
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "on the ground")
        input = far
        input.aircraft = nil
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "no fix")
        input = far
        input.leg = nil
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "no leg to fly")
    }

    /// A suppression starts the rule again from on-route.
    func testASuppressionResetsTheHysteresis() {
        var rule = OffRouteRule()
        XCTAssertNil(rule.update(flying(0.3)), "on the route: joined")
        XCTAssertNotNil(rule.update(flying(1.2)))
        var degraded = flying(0.8)
        degraded.gpsGood = false
        XCTAssertNil(rule.update(degraded))
        XCTAssertNil(rule.update(flying(0.8)), "0.8 NM shows only on the way down from above 1.0")
    }

    private func plan(next: Int) -> FlightPlan {
        var plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.4247, longitude: 7.1869)),
            FlightPlanWaypoint(name: "WPT", coordinate: .init(latitude: 47.20, longitude: 7.00)),
            FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.0839, longitude: 6.7928)),
        ])
        plan.currentWaypointIndex = next
        return plan
    }

    /// The leg is waypoint n−1 to n: none on the way to the departure, none once the destination is
    /// marked, none while diverting.
    func testTheActiveLegIsFromTheLastWaypointToTheNext() throws {
        XCTAssertNil(OffRouteRule.activeLeg(of: nil))
        XCTAssertNil(OffRouteRule.activeLeg(of: plan(next: 0)), "the leg to the departure")
        let second = try XCTUnwrap(OffRouteRule.activeLeg(of: plan(next: 2)))
        XCTAssertEqual(second.from.latitude, 47.20)
        XCTAssertEqual(second.to.latitude, 47.0839)
        XCTAssertNil(OffRouteRule.activeLeg(of: plan(next: 3)), "the destination marked")

        var diverting = plan(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                        leftRouteAt: 2)
        XCTAssertNil(OffRouteRule.activeLeg(of: diverting))
        let input = OffRouteRule.Input(plan: diverting, aircraft: abeam(5), inCircuits: false, airborne: true,
                                       gpsGood: true)
        XCTAssertTrue(input.diverting)
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: false))
    }

    /// From the plan, 2 NM off the second leg in flight: OFF ROUTE.
    func testFromThePlanAnAircraftOffTheLegIsOffRoute() throws {
        let flown = plan(next: 2)
        let leg = try XCTUnwrap(OffRouteRule.activeLeg(of: flown))
        let midpoint = CLLocationCoordinate2D(latitude: (leg.from.latitude + leg.to.latitude) / 2,
                                              longitude: (leg.from.longitude + leg.to.longitude) / 2)
        let off = CLLocationCoordinate2D(latitude: midpoint.latitude + 2 / 60, longitude: midpoint.longitude)
        let input = OffRouteRule.Input(plan: flown, aircraft: off, inCircuits: false, airborne: true, gpsGood: true)
        XCTAssertGreaterThan(try XCTUnwrap(OffRouteRule.evaluate(input, wasOffRoute: false)), 1.0)
        let onIt = OffRouteRule.Input(plan: flown, aircraft: midpoint, inCircuits: false, airborne: true, gpsGood: true)
        XCTAssertNil(OffRouteRule.evaluate(onIt, wasOffRoute: false))
    }

    func testAirborneAndGoodGPSForTheRule() {
        let now = Date()
        XCTAssertFalse(OffRouteRule.isAirborne(lineUpTime: nil, landingTime: nil))
        XCTAssertTrue(OffRouteRule.isAirborne(lineUpTime: now, landingTime: nil))
        XCTAssertFalse(OffRouteRule.isAirborne(lineUpTime: now, landingTime: now))

        XCTAssertTrue(OffRouteRule.gpsIsGood(isTracking: true, signal: .good, isSimulating: false))
        XCTAssertFalse(OffRouteRule.gpsIsGood(isTracking: true, signal: .degraded, isSimulating: false))
        XCTAssertFalse(OffRouteRule.gpsIsGood(isTracking: true, signal: .lost, isSimulating: false))
        XCTAssertFalse(OffRouteRule.gpsIsGood(isTracking: false, signal: .good, isSimulating: false))
        XCTAssertTrue(OffRouteRule.gpsIsGood(isTracking: true, signal: .degraded, isSimulating: true),
                      "a simulated position is held at degraded, and OFF ROUTE is what it is for")
    }

    // MARK: - OFF ROUTE never where the pilot is right (PR 4)

    /// West to east along 46.5°N, then north, then east: W0 the departure, W4 the destination, every leg
    /// 18 to 29 NM, the middle ones far from both fields.
    private let route: [CLLocationCoordinate2D] = [
        .init(latitude: 46.5, longitude: 6.5), .init(latitude: 46.5, longitude: 7.0),
        .init(latitude: 46.5, longitude: 7.5), .init(latitude: 46.8, longitude: 7.5),
        .init(latitude: 46.8, longitude: 8.2),
    ]

    private func route(next: Int) -> FlightPlan {
        var plan = FlightPlan(waypoints: route.enumerated().map { index, coordinate in
            FlightPlanWaypoint(name: "W\(index)", coordinate: coordinate)
        })
        plan.currentWaypointIndex = next
        return plan
    }

    /// `nm` miles north (south when negative) and `east` miles east of `point`.
    private func offset(_ point: CLLocationCoordinate2D, north nm: Double, east: Double = 0) -> CLLocationCoordinate2D {
        .init(latitude: point.latitude + nm / 60,
              longitude: point.longitude + east / (60 * cos(point.latitude * .pi / 180)))
    }

    private func inFlight(_ plan: FlightPlan, at aircraft: CLLocationCoordinate2D) -> OffRouteRule.Input {
        OffRouteRule.Input(plan: plan, aircraft: aircraft, inCircuits: false, airborne: true, gpsGood: true)
    }

    /// The legs that count: the one just flown, the one flown, every one after it; none before the take-off,
    /// after the destination or diverting. The fields: the departure and the destination.
    func testTheRouteIsTheLegFlownAndTheLegsAroundIt() throws {
        func legs(_ next: Int) -> [Double] {
            OffRouteRule.otherLegs(of: route(next: next)).map(\.to.longitude)
        }
        XCTAssertEqual(legs(1), [7.5, 7.5, 8.2], "on the first leg: every one after it")
        XCTAssertEqual(legs(2), [7.0, 7.5, 8.2], "the one just flown (to W1), then W3 and W4's")
        XCTAssertEqual(legs(4), [7.5], "on the last leg: the one just flown")
        XCTAssertEqual(legs(0), [], "the leg to the departure: none")
        XCTAssertEqual(legs(5), [], "the destination marked: none")
        var diverting = route(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.95, longitude: 6.86, leftRouteAt: 2)
        XCTAssertEqual(OffRouteRule.otherLegs(of: diverting).count, 0)
        let fields = OffRouteRule.fields(of: route(next: 2))
        XCTAssertEqual(fields.map(\.longitude), [6.5, 8.2])
        XCTAssertEqual(OffRouteRule.fields(of: nil).count, 0)
        let input = inFlight(route(next: 2), at: route[1])
        XCTAssertEqual(input.target, 2)
        XCTAssertEqual(input.otherLegs.count, 3)
        XCTAssertEqual(input.fields.count, 2)
    }

    /// Flown past the waypoint before the flight marks it (a catch-up runs every 15 s), MARK pressed early,
    /// a waypoint taken back and flown past: on the route, though miles off the leg flown.
    func testTheLegsAroundTheLegFlownAreTheRouteToo() throws {
        let pastW2 = offset(route[2], north: 2)                         // on W2 → W3, W2 still the target
        XCTAssertEqual(OffRouteRule.crossTrackNM(pastW2, leg: try XCTUnwrap(OffRouteRule.activeLeg(of: route(next: 2)))),
                       2, accuracy: 0.05, "2 NM past the leg's end")
        XCTAssertEqual(try XCTUnwrap(OffRouteRule.routeDistance(inFlight(route(next: 2), at: pastW2))), 0, accuracy: 0.05)

        let beforeW2 = offset(route[2], north: 0, east: -1.5)           // W2 marked 1.5 NM early, on W1 → W2
        XCTAssertEqual(try XCTUnwrap(OffRouteRule.routeDistance(inFlight(route(next: 3), at: beforeW2))), 0, accuracy: 0.05)

        let onLastLeg = offset(route[3], north: 0, east: 10)            // W2 taken back, flown on to W3 → W4
        XCTAssertEqual(try XCTUnwrap(OffRouteRule.routeDistance(inFlight(route(next: 2), at: onLastLeg))), 0, accuracy: 0.05)

        // Off every one of them, it speaks.
        let off = offset(CLLocationCoordinate2D(latitude: 46.65, longitude: 7.5), north: 0, east: 2)
        var rule = OffRouteRule()
        XCTAssertNil(rule.update(inFlight(route(next: 3), at: CLLocationCoordinate2D(latitude: 46.65, longitude: 7.5))))
        XCTAssertEqual(try XCTUnwrap(rule.update(inFlight(route(next: 3), at: off))), 2, accuracy: 0.05)
    }

    /// Within 5 NM of the departure and the destination, the circuit, its joining and its leaving are
    /// flown, not the line: dark.
    func testNearTheRoutesFieldsOffRouteIsDark() throws {
        let nearDeparture = offset(route[0], north: 1.5, east: 3)       // 3.4 NM from W0, 1.5 NM off W0 → W1
        XCTAssertNil(OffRouteRule.routeDistance(inFlight(route(next: 1), at: nearDeparture)))
        let pastIt = offset(route[0], north: 1.5, east: 6)              // 6.2 NM out
        XCTAssertEqual(try XCTUnwrap(OffRouteRule.routeDistance(inFlight(route(next: 1), at: pastIt))), 1.5, accuracy: 0.05)
        let joining = offset(route[4], north: -1.6, east: -2)           // the destination's downwind
        XCTAssertNil(OffRouteRule.routeDistance(inFlight(route(next: 4), at: joining)))
        XCTAssertTrue(OffRouteRule.isNearField(route[4], fields: [route[4]]))
        XCTAssertFalse(OffRouteRule.isNearField(route[2], fields: OffRouteRule.fields(of: route(next: 2))))
    }

    /// The take-off: the aircraft leaves the field on the runway's heading and joins the first leg miles
    /// out. OFF ROUTE waits until it has been on the route once (within 0.7 NM), then speaks as before.
    func testTheDepartureJoinsTheRouteBeforeOffRouteSpeaks() {
        var rule = OffRouteRule()
        var ground = inFlight(route(next: 0), at: route[0])
        ground.airborne = false
        XCTAssertNil(rule.update(ground))
        XCTAssertNil(rule.update(inFlight(route(next: 1), at: offset(route[0], north: 0.5))), "the take-off marks W0")
        let w1 = route[1]
        XCTAssertNil(rule.update(inFlight(route(next: 1), at: offset(w1, north: 1.4, east: -12))), "6 NM out, 1.4 off: joining")
        XCTAssertFalse(rule.hasJoinedRoute)
        XCTAssertNil(rule.update(inFlight(route(next: 1), at: offset(w1, north: 1.1, east: -9))))
        XCTAssertNil(rule.update(inFlight(route(next: 1), at: offset(w1, north: 0.5, east: -6))), "on the leg: joined")
        XCTAssertTrue(rule.hasJoinedRoute)
        XCTAssertEqual(rule.update(inFlight(route(next: 1), at: offset(w1, north: 1.2, east: -4))) ?? 0, 1.2, accuracy: 0.05)
    }

    /// The next waypoint, by a passage or MARK, keeps the route joined. Any other new target (DIRECT, RESUME
    /// LEG, UNDO, the route resumed) makes the aircraft join it again first.
    func testANewTargetOtherThanTheNextWaypointJoinsAgain() {
        var rule = OffRouteRule()
        let midW1W2 = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.25)
        let midW2W3 = CLLocationCoordinate2D(latitude: 46.65, longitude: 7.5)
        XCTAssertNil(rule.update(inFlight(route(next: 2), at: midW1W2)))
        XCTAssertNotNil(rule.update(inFlight(route(next: 2), at: offset(midW1W2, north: 1.5))))
        // W2 passed: still off, said at once.
        XCTAssertNotNil(rule.update(inFlight(route(next: 3), at: offset(midW2W3, north: 0, east: 1.5))))
        // RESUME LEG back to W2 from there: joined again first.
        XCTAssertNil(rule.update(inFlight(route(next: 2), at: offset(midW2W3, north: 0, east: 1.5))))
        XCTAssertFalse(rule.hasJoinedRoute)
        XCTAssertNil(rule.update(inFlight(route(next: 2), at: midW2W3)), "back on the route")
        XCTAssertTrue(rule.hasJoinedRoute)
        // DIRECT to W4, 4 NM east of W2 → W3: on the way, not off.
        XCTAssertNil(rule.update(inFlight(route(next: 4), at: CLLocationCoordinate2D(latitude: 46.6, longitude: 7.6))))
        XCTAssertFalse(rule.hasJoinedRoute)
        XCTAssertNil(rule.update(inFlight(route(next: 4), at: offset(route[3], north: -0.4, east: 6))), "joined W3 → W4")
        XCTAssertNotNil(rule.update(inFlight(route(next: 4), at: offset(route[3], north: -1.3, east: 9))))
    }

    /// GPS lost a moment keeps the route joined; diverting, circuits and the ground start the joining over.
    func testOnlyLeavingTheRouteOnPurposeStartsTheJoiningOver() {
        let midW1W2 = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.25)
        var rule = OffRouteRule()
        XCTAssertNil(rule.update(inFlight(route(next: 2), at: midW1W2)))
        var degraded = inFlight(route(next: 2), at: offset(midW1W2, north: 1.2))
        degraded.gpsGood = false
        XCTAssertNil(rule.update(degraded))
        XCTAssertTrue(rule.hasJoinedRoute, "a GPS dropout is not leaving the route")
        XCTAssertNotNil(rule.update(inFlight(route(next: 2), at: offset(midW1W2, north: 1.2))))

        var diverting = route(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.95, longitude: 6.86, leftRouteAt: 2)
        XCTAssertNil(rule.update(inFlight(diverting, at: offset(midW1W2, north: 5))))
        XCTAssertFalse(rule.hasJoinedRoute)
        XCTAssertNil(rule.update(inFlight(route(next: 2), at: offset(midW1W2, north: 3))), "the route resumed: on the way back")
    }

    /// The Cockpit's OFF ROUTE: to the tenth, said again only when it changes.
    @MainActor
    func testTheCockpitKeepsOffRouteToTheTenth() {
        let state = CockpitMapState()
        let midW1W2 = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.25)
        state.note(inFlight(route(next: 2), at: midW1W2))
        XCTAssertNil(state.offRouteNM)
        state.note(inFlight(route(next: 2), at: offset(midW1W2, north: 1.234)))
        XCTAssertEqual(state.offRouteNM ?? 0, 1.2, accuracy: 1e-9)
        state.showWholeRoute()
        state.showHazards()
        XCTAssertEqual(state.wholeRouteRequest, 1)
        XCTAssertEqual(state.hazardsRequest, 1)
    }

    /// The flight's own input: airborne from LINE UP to the landing, good GPS as the rule takes it.
    func testTheInputInFlight() {
        let input = OffRouteRule.Input(plan: route(next: 2), aircraft: route[1], circuits: false,
                                       lineUpTime: Date(), landingTime: nil, isTracking: true, signal: .good,
                                       isSimulating: false)
        XCTAssertTrue(input.airborne && input.gpsGood && !input.inCircuits)
        let landed = OffRouteRule.Input(plan: route(next: 2), aircraft: route[1], circuits: true, lineUpTime: Date(),
                                        landingTime: Date(), isTracking: true, signal: .degraded, isSimulating: false)
        XCTAssertFalse(landed.airborne || landed.gpsGood)
        XCTAssertTrue(landed.inCircuits)
    }

    /// The slot's other inputs as the map gathers them: the zoom as the map estimates it, the SIGMET named
    /// as the sheet names it.
    @MainActor
    func testTheMapsZoomAndTheSigmetsName() {
        XCTAssertEqual(ChartAvailability.zoom(latitudeDelta: 360), 0)
        XCTAssertEqual(ChartAvailability.zoom(latitudeDelta: 0.1), 12)
        XCTAssertEqual(ChartAvailability.zoom(latitudeDelta: 0.7), 9)
        XCTAssertEqual(ChartAvailability.zoom(latitudeDelta: 0), 11)
        XCTAssertEqual(ChartAvailability.zoom(latitudeDelta: .infinity), 11)
        XCTAssertEqual(CockpitChartChrome.sigmetSummary(hazard("TURB", crossesRoute: true)), "TURB · " + L10n.Nav.sigmetOnRoute)
        XCTAssertEqual(CockpitChartChrome.sigmetSummary(hazard("TS", inside: true, distance: 0)), "TS · " + L10n.Nav.sigmetOverhead)
    }

    // MARK: - CHART OFFLINE

    private let overSwitzerland = MKCoordinateRegion(center: .init(latitude: 46.8, longitude: 8.2),
                                                     span: .init(latitudeDelta: 1, longitudeDelta: 1.4))
    private let overParis = MKCoordinateRegion(center: .init(latitude: 48.85, longitude: 2.35),
                                               span: .init(latitudeDelta: 1, longitudeDelta: 1.4))

    /// Online, the ICAO chart, both caches downloaded, zoom 9 over Switzerland.
    private func chart(_ layer: MapLayerType = .icao, offlineMode: Bool = false, connected: Bool = true,
                       icao: Bool = true, glider: Bool = false, forceICAO: Bool = false, zoom: Int = 9,
                       region: MKCoordinateRegion? = nil) -> ChartAvailability.Input {
        ChartAvailability.Input(selectedLayer: layer, offlineMode: offlineMode, isConnected: connected,
                                icaoCached: icao, gliderCached: glider, forceICAOChartLayer: forceICAO,
                                zoom: zoom, region: region ?? overSwitzerland)
    }

    private func offline(_ input: ChartAvailability.Input) -> Bool {
        ChartAvailability.isChartOffline(input)
    }

    /// Online, the chart can always be fetched: today's CACHED goes dark, and so does every layer.
    func testOnlineTheChartIsNeverOffline() {
        XCTAssertFalse(offline(chart()), "today's CACHED")
        for layer in MapLayerType.allCases {
            XCTAssertFalse(offline(chart(layer, icao: false, zoom: 14, region: overParis)), "\(layer)")
        }
    }

    /// Strict offline mode (today's red OFFLINE): dark where the cache covers; CHART OFFLINE zoomed out
    /// past 7 or outside Switzerland, network or not.
    func testStrictOfflineModeIsDarkWhereTheCacheCovers() {
        XCTAssertFalse(offline(chart(offlineMode: true)))
        XCTAssertFalse(offline(chart(offlineMode: true, zoom: CacheableLayer.icao.minZoom)))
        XCTAssertTrue(offline(chart(offlineMode: true, zoom: CacheableLayer.icao.minZoom - 1)))
        XCTAssertTrue(offline(chart(offlineMode: true, region: overParis)))
        XCTAssertTrue(offline(chart(offlineMode: true, connected: true, region: overParis)),
                      "strict mode never fetches")
    }

    /// Strict mode draws the ICAO chart whatever was picked.
    func testStrictOfflineModeDrawsTheICAOChart() {
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(.satellite, offlineMode: true)), .icao)
        XCTAssertFalse(offline(chart(.satellite, offlineMode: true, connected: false)))
    }

    /// The setting without an ICAO cache isn't strict mode: the map ignores it and fetches.
    func testOfflineModeWithoutACacheStillFetches() {
        let input = chart(offlineMode: true, icao: false)
        XCTAssertFalse(ChartAvailability.isStrictOffline(input))
        XCTAssertTrue(ChartAvailability.isOnline(input))
        XCTAssertFalse(offline(input))
        XCTAssertTrue(offline(chart(offlineMode: true, connected: false, icao: false)))
    }

    /// No network on a covered ICAO chart: dark.
    func testNoNetworkOverTheCachedICAOChartIsDark() {
        XCTAssertFalse(offline(chart(connected: false)))
        XCTAssertFalse(offline(chart(connected: false, forceICAO: true, zoom: 13)), "the ICAO chart forced, zoomed in")
    }

    /// No network on any other layer, zoom or area: CHART OFFLINE.
    func testNoNetworkAnywhereElseIsChartOffline() {
        for layer in [MapLayerType.standard, .satellite, .landeskarten, .swissimage] {
            XCTAssertTrue(offline(chart(layer, connected: false)), "\(layer): MapKit's cache is not ours to vouch for")
        }
        XCTAssertTrue(offline(chart(connected: false, zoom: 6)), "zoomed out past the cache")
        XCTAssertTrue(offline(chart(connected: false, region: overParis)), "outside the cache's box")
        XCTAssertTrue(offline(chart(connected: false, icao: false)), "nothing downloaded")
    }

    /// Above zoom 11 the ICAO layer is the glider chart, cached on its own.
    func testTheGliderChartNeedsItsOwnCache() {
        let zoomedIn = CacheableLayer.icao.maxZoom + 1
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(zoom: zoomedIn)), .glider)
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(zoom: CacheableLayer.icao.maxZoom)), .icao)
        XCTAssertTrue(offline(chart(connected: false, glider: false, zoom: zoomedIn)))
        XCTAssertFalse(offline(chart(connected: false, glider: true, zoom: zoomedIn)))
        // Forced, the ICAO chart stays, and its cache covers.
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(forceICAO: true, zoom: zoomedIn)), .icao)
    }

    /// Strict mode draws the glider chart only with its cache; without it the ICAO chart is forced.
    func testStrictOfflineModeTurnsToTheGliderChartOnlyWithItsCache() {
        let zoomedIn = CacheableLayer.icao.maxZoom + 1
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(offlineMode: true, glider: true, zoom: zoomedIn)), .glider)
        XCTAssertFalse(offline(chart(offlineMode: true, glider: true, zoom: zoomedIn)))
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(offlineMode: true, glider: false, zoom: zoomedIn)), .icao)
        XCTAssertFalse(offline(chart(offlineMode: true, glider: false, zoom: zoomedIn)))
    }

    /// Any part of the screen over the cache's box counts; the box is the download's own.
    func testTheRegionMeetsTheCacheBoxWhenAnyOfItIsOverIt() {
        XCTAssertTrue(ChartAvailability.regionMeetsCacheBox(overSwitzerland))
        XCTAssertFalse(ChartAvailability.regionMeetsCacheBox(overParis))
        let box = OfflineMapManager.switzerlandBounds
        let straddlingTheWest = MKCoordinateRegion(center: .init(latitude: 46.2, longitude: box.minLon - 0.5),
                                                   span: .init(latitudeDelta: 0.5, longitudeDelta: 1.2))
        XCTAssertTrue(ChartAvailability.regionMeetsCacheBox(straddlingTheWest))
        let justWest = MKCoordinateRegion(center: .init(latitude: 46.2, longitude: box.minLon - 0.7),
                                          span: .init(latitudeDelta: 0.5, longitudeDelta: 1.2))
        XCTAssertFalse(ChartAvailability.regionMeetsCacheBox(justWest))
    }

    // MARK: - The edge arrow

    private let square = CGSize(width: 400, height: 400)
    private let centre = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.5)
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: centre, span: .init(latitudeDelta: 0.6, longitudeDelta: 0.8))
    }

    private func arrow(to aircraft: CLLocationCoordinate2D, heading: Double = 0,
                       size: CGSize? = nil) -> OwnshipEdgeArrow.Placement? {
        OwnshipEdgeArrow.place(aircraft: aircraft, region: region, heading: heading, size: size ?? square, inset: 20)
    }

    /// The aircraft on screen: no arrow.
    func testNoArrowWhileTheAircraftIsOnScreen() {
        XCTAssertNil(arrow(to: centre))
        XCTAssertNil(arrow(to: .init(latitude: 46.5, longitude: 7.85)), "near the edge, inside the inset")
        XCTAssertNil(arrow(to: centre, heading: 137))
    }

    /// North up: the arrow on the edge facing the aircraft, pointing at it.
    func testNorthUpTheArrowFacesTheAircraft() throws {
        let east = try XCTUnwrap(arrow(to: .init(latitude: 46.5, longitude: 9.5)))
        XCTAssertEqual(east.point.x, 380, accuracy: 1e-6)
        XCTAssertEqual(east.point.y, 200, accuracy: 1e-6)
        XCTAssertEqual(east.degrees, 90, accuracy: 1e-6)

        let north = try XCTUnwrap(arrow(to: .init(latitude: 48.5, longitude: 7.5)))
        XCTAssertEqual(north.point.x, 200, accuracy: 1e-6)
        XCTAssertEqual(north.point.y, 20, accuracy: 1e-6)
        XCTAssertEqual(north.degrees, 0, accuracy: 1e-6)

        let west = try XCTUnwrap(arrow(to: .init(latitude: 46.5, longitude: 5.0)))
        XCTAssertEqual(west.point.x, 20, accuracy: 1e-6)
        XCTAssertEqual(west.degrees, 270, accuracy: 1e-6)

        let south = try XCTUnwrap(arrow(to: .init(latitude: 44.5, longitude: 7.5)))
        XCTAssertEqual(south.point.y, 380, accuracy: 1e-6)
        XCTAssertEqual(south.degrees, 180, accuracy: 1e-6)
    }

    /// Track up, the chart turns by the heading, and so does the arrow.
    func testTrackUpTheArrowTurnsWithTheChart() throws {
        // Heading east: an aircraft further east is ahead, at the top.
        let ahead = try XCTUnwrap(arrow(to: .init(latitude: 46.5, longitude: 9.5), heading: 90))
        XCTAssertEqual(ahead.point.x, 200, accuracy: 1e-6)
        XCTAssertEqual(ahead.point.y, 20, accuracy: 1e-6)
        XCTAssertEqual(ahead.degrees, 0, accuracy: 1e-6)
        // And one to the north is on the left.
        let left = try XCTUnwrap(arrow(to: .init(latitude: 48.5, longitude: 7.5), heading: 90))
        XCTAssertEqual(left.point.x, 20, accuracy: 1e-6)
        XCTAssertEqual(left.degrees, 270, accuracy: 1e-6)
    }

    /// The scale comes from the region's width: the region's east edge is the chart's right edge north
    /// up and, heading east on a wide chart, its top edge (the turned chart's bounding region).
    func testTheProjectionScalesByTheRegionsWidth() throws {
        let eastEdge = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.5 + 0.4)
        let northUp = try XCTUnwrap(OwnshipEdgeArrow.project(eastEdge, region: region, heading: 0, size: square))
        XCTAssertEqual(northUp.x, 400, accuracy: 1e-6)
        XCTAssertEqual(northUp.y, 200, accuracy: 1e-6)
        let wide = CGSize(width: 400, height: 200)
        let trackUp = try XCTUnwrap(OwnshipEdgeArrow.project(eastEdge, region: region, heading: 90, size: wide))
        XCTAssertEqual(trackUp.x, 200, accuracy: 1e-6)
        XCTAssertEqual(trackUp.y, 0, accuracy: 1e-6)
    }

    /// Towards a corner, the ray leaves through the corner.
    func testTheArrowLeavesThroughTheEdgeTheRayCrosses() throws {
        let corner = try XCTUnwrap(OwnshipEdgeArrow.place(screenPoint: CGPoint(x: 1200, y: 1200), size: square,
                                                          inset: 20))
        XCTAssertEqual(corner.point.x, 380, accuracy: 1e-9)
        XCTAssertEqual(corner.point.y, 380, accuracy: 1e-9)
        XCTAssertEqual(corner.degrees, 135, accuracy: 1e-9)
        let shallow = try XCTUnwrap(OwnshipEdgeArrow.place(screenPoint: CGPoint(x: 200 + 360, y: 200 - 90),
                                                           size: square, inset: 20))
        XCTAssertEqual(shallow.point.x, 380, accuracy: 1e-9)
        XCTAssertEqual(shallow.point.y, 200 - 45, accuracy: 1e-9)
    }

    func testNoArrowOnAChartTooSmallForItsInset() {
        XCTAssertNil(OwnshipEdgeArrow.place(screenPoint: CGPoint(x: 900, y: 0), size: CGSize(width: 30, height: 400),
                                            inset: 20))
        XCTAssertNil(OwnshipEdgeArrow.place(aircraft: centre, region: region, heading: 0, size: .zero, inset: 0))
    }

    // MARK: - The scale

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A zoom shows the scale; it goes 2 s after the last change.
    func testTheScaleShowsForTwoSecondsAfterTheLastZoom() {
        var scale = ScaleVisibility()
        scale.note(zoom: 50_000, at: t0)
        XCTAssertFalse(scale.isVisible(at: t0), "the first value is the reference")
        scale.note(zoom: 45_000, at: t0.addingTimeInterval(1))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(1)))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(2.9)))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(scale.hidesAt, t0.addingTimeInterval(3))

        // Another change keeps it up, 2 s from that one.
        scale.note(zoom: 40_000, at: t0.addingTimeInterval(2.5))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(4.4)))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(4.5)))
    }

    /// Following the aircraft moves the centre, not the zoom: no scale. Nor for a change of 1 % or less.
    func testTheScaleIgnoresFollowingAndJitter() {
        var scale = ScaleVisibility()
        for second in 0..<10 {
            scale.note(zoom: 50_000, at: t0.addingTimeInterval(Double(second)))
        }
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(10)))
        scale.note(zoom: 50_400, at: t0.addingTimeInterval(11))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(11)), "0.8 %")
        XCTAssertNil(scale.hidesAt)
    }

    /// A slow pinch counts from the last change, not from the last fix: 0.6 % steps show it on the second.
    func testASlowZoomStillShowsTheScale() {
        var scale = ScaleVisibility()
        scale.note(zoom: 50_000, at: t0)
        scale.note(zoom: 50_300, at: t0.addingTimeInterval(0.1))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(0.1)))
        scale.note(zoom: 50_600, at: t0.addingTimeInterval(0.2))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(0.2)))
    }
}
