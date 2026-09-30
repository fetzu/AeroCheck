import XCTest
import CoreLocation
@testable import AeroCheck

/// The cruise speed a plan's legs are timed with (6.1): the model that turns the aircraft's KIAS into a
/// true airspeed at each leg's level, where the figure comes from (the pilot's, learned, the aircraft's
/// data, 100 kt), the airspeeds the pilot typed, what is filed in ICAO Items 15 and 16, and the fields
/// that carry it (metadata, settings, plans saved before 6.1).
final class CruiseSpeedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FlightPlan.planningCalibrationProvider = nil
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
    }

    override func tearDown() {
        FlightPlan.planningCalibrationProvider = nil
        super.tearDown()
    }

    // MARK: - The model

    /// The analysis's numbers: 97 KIAS is 104.5 kt true at the 5,000 ft reference, 108 at F-HVXA's
    /// 8,500 ft Alpine leg (it flew 107; a constant IAS says 110), 101 at 2,000 ft.
    func testTheCruiseKIASBecomesATrueAirspeedByAltitude() {
        XCTAssertEqual(CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 5_000), 104.5, accuracy: 0.2)
        XCTAssertEqual(CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 8_500), 108.3, accuracy: 0.3)
        XCTAssertEqual(CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 2_000), 101.4, accuracy: 0.3)
        let constantIAS = 97 / CruiseSpeedModel.densityRatio(altitudeFt: 8_500).squareRoot()
        XCTAssertLessThan(CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 8_500), constantIAS - 1.5,
                          "fixed power: less than a constant IAS gives up high")
    }

    func testTheBasisIsTheInverseOfTheConversion() {
        for altitude in [0.0, 3_000, 5_000, 9_500] {
            let tas = CruiseSpeedModel.trueAirspeed(kias: 105, altitudeFt: altitude)
            XCTAssertEqual(CruiseSpeedModel.basisKIAS(trueAirspeed: tas, altitudeFt: altitude), 105, accuracy: 1e-9)
        }
    }

    func testAnAbsurdAltitudeStaysInTheAtmosphere() {
        XCTAssertTrue(CruiseSpeedModel.trueAirspeed(kias: 100, altitudeFt: .infinity).isFinite)
        XCTAssertTrue(CruiseSpeedModel.trueAirspeed(kias: 100, altitudeFt: 1e9).isFinite)
    }

    // MARK: - Where the figure comes from

    private func samples(_ values: [Double]) -> [EETCalibration.Sample] {
        values.enumerated().map { EETCalibration.Sample(date: Date(timeIntervalSince1970: Double($0.offset) * 86_400), value: $0.element) }
    }

    func testThePilotsFigureWinsOverEverything() {
        let resolved = CruiseSpeed.resolve(manualKIAS: 92, aircraftDataKIAS: 97, learnedSamples: samples([99, 99, 99, 99, 99]))
        XCTAssertEqual(resolved, CruiseSpeed(kias: 92, source: .manual))
    }

    func testLearnedNeedsFiveFlightsAndOutranksTheAircraftData() {
        XCTAssertEqual(CruiseSpeed.resolve(manualKIAS: nil, aircraftDataKIAS: 97, learnedSamples: samples([101, 101, 101, 101])),
                       CruiseSpeed(kias: 97, source: .aircraftData), "four flights are not enough")
        let learned = CruiseSpeed.resolve(manualKIAS: nil, aircraftDataKIAS: 97, learnedSamples: samples([101, 101, 101, 101, 101]))
        XCTAssertEqual(learned.source, .learned)
        XCTAssertEqual(learned.flights, 5)
        XCTAssertEqual(learned.kias, 99, accuracy: 1e-9, "halfway to the flights' 101 with 5 of the 10 that give it full weight")
    }

    func testWithNothingKnownTheCruiseIs100Knots() {
        XCTAssertEqual(CruiseSpeed.resolve(manualKIAS: nil, aircraftDataKIAS: nil, learnedSamples: []), .standard)
        XCTAssertEqual(CruiseSpeed.standard.kias, 100)
    }

    func testAFigureNoAircraftCruisesAtIsSkipped() {
        XCTAssertEqual(CruiseSpeed.resolve(manualKIAS: 900, aircraftDataKIAS: 12, learnedSamples: []), .standard)
        XCTAssertEqual(CruiseSpeed.resolve(manualKIAS: .nan, aircraftDataKIAS: 105, learnedSamples: []).source, .aircraftData)
    }

    /// Learned is drawn towards the aircraft's figure (100 kt without one) until ten flights, and never
    /// moves more than 15 % from it.
    func testLearnedIsBlendedTowardsTheSeedAndClamped() {
        let ten = EETCalibration.learnedCruise(samples(Array(repeating: 110, count: 10)), seedKIAS: 100)
        XCTAssertEqual(ten?.kias ?? 0, 110, accuracy: 1e-9, "full weight at ten flights")
        let wild = EETCalibration.learnedCruise(samples(Array(repeating: 150, count: 12)), seedKIAS: 100)
        XCTAssertEqual(wild?.kias ?? 0, 115, accuracy: 1e-9, "clamped at +15 %")
        let slow = EETCalibration.learnedCruise(samples(Array(repeating: 60, count: 12)), seedKIAS: 100)
        XCTAssertEqual(slow?.kias ?? 0, 85, accuracy: 1e-9, "clamped at -15 %")
    }

    /// The median of the last 20 flights: an old habit doesn't hold the figure back for ever.
    func testLearnedReadsTheLastTwentyFlights() {
        let learned = EETCalibration.learnedCruise(samples(Array(repeating: 90, count: 30) + Array(repeating: 104, count: 20)),
                                                   seedKIAS: 100)
        XCTAssertEqual(learned?.kias ?? 0, 104, accuracy: 1e-9)
        XCTAssertEqual(learned?.flights, 20)
    }

    // MARK: - Legs

    private let lszq = CLLocationCoordinate2D(latitude: 47.3927, longitude: 7.0283)
    private let mid = CLLocationCoordinate2D(latitude: 47.20, longitude: 7.30)
    private let lsgn = CLLocationCoordinate2D(latitude: 46.9575, longitude: 6.8646)

    private func plan(altitudes: [Double?] = [1_400, 8_500, 1_400], typed: [Int?] = [nil, nil, nil]) -> FlightPlan {
        var plan = FlightPlan(name: "LSZQ → LSGN", aircraftRegistration: "F-HVXA")
        plan.waypoints = [
            FlightPlanWaypoint(name: "LSZQ", coordinate: lszq, altitude: altitudes[0], plannedGroundSpeed: typed[0]),
            FlightPlanWaypoint(name: "MID", coordinate: mid, altitude: altitudes[1], plannedGroundSpeed: typed[1]),
            FlightPlanWaypoint(name: "LSGN", coordinate: lsgn, altitude: altitudes[2], plannedGroundSpeed: typed[2]),
        ]
        return plan
    }

    private func providing(_ kias: Double, source: CruiseSpeed.Source = .aircraftData) {
        FlightPlan.planningCalibrationProvider = { plan in
            var calibration = FlightPlan.PlanningCalibration.standard(for: plan)
            calibration.cruise = CruiseSpeed(kias: kias, source: source)
            return calibration
        }
    }

    /// Each leg at the aircraft's cruise converted at its level: the higher of its two ends, since the
    /// route starts and ends at field elevation.
    func testEachLegIsTimedAtTheCruiseTrueAirspeedOfItsLevel() throws {
        providing(97)
        var p = plan()
        p.calculateRouteData()
        let expected = CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 8_500).rounded()
        XCTAssertEqual(try XCTUnwrap(p.legPlanning(from: 0)?.airspeedKt), Int(expected))
        XCTAssertEqual(try XCTUnwrap(p.legPlanning(from: 1)?.airspeedKt), Int(expected))
        XCTAssertEqual(p.plannedCruise, CruiseSpeed(kias: 97, source: .aircraftData), "kept with the plan")
        let leg = try XCTUnwrap(p.legPlanning(from: 0))
        XCTAssertEqual(try XCTUnwrap(p.waypoints[0].estimatedElapsedTime), leg.distanceNM / expected * 3600, accuracy: 1)
    }

    func testALegWithoutAltitudesIsTimedAtTheReferenceLevel() throws {
        providing(97)
        let p = plan(altitudes: [nil, nil, nil])
        XCTAssertEqual(p.cruiseAltitude(ofLegFrom: 0), CruiseSpeedModel.referenceAltitudeFt)
        XCTAssertEqual(try XCTUnwrap(p.legPlanning(from: 0)?.airspeedKt),
                       Int(CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 5_000).rounded()))
    }

    /// The airspeed the pilot typed on a waypoint is the leg's, as a true airspeed, whatever the aircraft.
    func testATypedAirspeedKeepsPriority() throws {
        providing(97)
        let p = plan(typed: [88, nil, nil])
        XCTAssertEqual(try XCTUnwrap(p.legPlanning(from: 0)?.airspeedKt), 88)
        XCTAssertNotEqual(try XCTUnwrap(p.legPlanning(from: 1)?.airspeedKt), 88)
    }

    /// A new waypoint gets no airspeed: its leg follows the aircraft's figure, whatever it becomes. Until
    /// 6.1 each one was seeded with 100 kt.
    @MainActor
    func testANewWaypointIsNotSeededWithAnAirspeed() throws {
        let manager = makeTestPlanManager()
        let created = manager.createFlightPlan(name: "Test", aircraftTypeId: "pa28-181", aircraftRegistration: "HB-PFA")
        manager.addWaypoint(to: created.id, coordinate: lszq, name: "LSZQ")
        manager.insertWaypoint(to: created.id, at: 1, coordinate: lsgn, name: "LSGN")
        manager.insertWaypoint(FlightPlanWaypoint(name: "MID", coordinate: mid), to: created.id, at: 1)
        let saved = try XCTUnwrap(manager.flightPlans.first { $0.id == created.id })
        XCTAssertEqual(saved.waypoints.count, 3)
        XCTAssertTrue(saved.waypoints.allSatisfy { $0.plannedGroundSpeed == nil })
    }

    // MARK: - Plans saved before 6.1

    /// Every waypoint was seeded with 100 kt until 6.1, so an older plan's 100 is not a choice: its leg
    /// takes the aircraft's cruise now. Another figure was typed, and stays.
    func testAnOlderPlansSeededAirspeedIsClearedAndATypedOneKept() throws {
        var legacy = plan(typed: [100, 92, nil])
        legacy.calculateRouteData()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "typedAirspeedsOnly")
        let decoded = try JSONDecoder().decode(FlightPlan.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.waypoints[0].plannedGroundSpeed)
        XCTAssertEqual(decoded.waypoints[1].plannedGroundSpeed, 92)
        XCTAssertEqual(decoded.typedAirspeedsOnly, true)

        let saved6_1 = try JSONDecoder().decode(FlightPlan.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(saved6_1.waypoints[0].plannedGroundSpeed, 100, "typed on a 6.1 plan: the pilot's")
    }

    /// The same rule for an AeroCheck GPX: an older file carries 100 on every waypoint, a 6.1 file says
    /// its airspeeds are the pilot's.
    func testAGPXFromAnOlderBuildLosesItsSeededAirspeeds() throws {
        let p = plan(typed: [100, 92, nil])
        let current = try XCTUnwrap(FlightPlanGPXParser(data: Data(p.toGPX().utf8)).parse())
        XCTAssertEqual(current.waypoints.map(\.plannedGroundSpeed), [100, 92, nil])

        let older = p.toGPX().replacingOccurrences(of: "\n        <ac:typedAirspeeds>true</ac:typedAirspeeds>", with: "")
        let imported = try XCTUnwrap(FlightPlanGPXParser(data: Data(older.utf8)).parse())
        XCTAssertEqual(imported.waypoints.map(\.plannedGroundSpeed), [nil, 92, nil])
    }

    // MARK: - ICAO

    /// Item 15 files the true airspeed at the planned level; Item 16 the time from take-off to over the
    /// destination, without the arrival allowance (ICAO Doc 4444).
    func testICAOItemsFifteenAndSixteen() throws {
        FlightPlan.planningCalibrationProvider = { plan in
            FlightPlan.PlanningCalibration(cruise: CruiseSpeed(kias: 97, source: .aircraftData),
                                           departureAllowance: EETAllowance(minutes: 1, aerodrome: "LSZQ", source: .aerodrome, flights: 6),
                                           arrivalAllowance: EETAllowance(minutes: 8, aerodrome: "LSGN", source: .aerodrome, flights: 4))
        }
        var p = plan()
        p.calculateRouteData()
        let fpl = p.toICAOFlightPlan()
        let tas = Int(CruiseSpeedModel.trueAirspeed(kias: 97, altitudeFt: 8_500).rounded())
        XCTAssertTrue(fpl.contains(String(format: "-N%04dA085", tas)), fpl)

        XCTAssertEqual(p.eetToDestination, p.totalEET - 8 * 60, accuracy: 1e-6)
        let seconds = Int(p.eetToDestination)
        let item16 = String(format: "-LSGN%02d%02d", seconds / 3600, (seconds % 3600) / 60)
        XCTAssertTrue(fpl.contains(item16), "Item 16 is \(item16), got:\n\(fpl)")
        let withArrival = Int(p.totalEET)
        XCTAssertFalse(fpl.contains(String(format: "-LSGN%02d%02d", withArrival / 3600, (withArrival % 3600) / 60)))
    }

    func testItemFifteenKeepsAnAirspeedThePilotTyped() {
        providing(97)
        var p = plan(typed: [nil, 120, nil])
        p.calculateRouteData()
        XCTAssertTrue(p.toICAOFlightPlan().contains("-N0120"))
    }

    // MARK: - The aircraft's data

    private let meta = #"""
    {"id":"dr400-140b","aircraftType":"DR400","registration":"HB-KFD","modelName":"Robin DR400/140B",
     "shortModelName":"DR400","version":"1.0","lastUpdated":"x","isFree":false,"stallSpeed":50,
     "pageCount":4,"hasAccess":true%@}
    """#

    func testTheMetadataDecodesTheCruiseSpeedAndOlderResponsesWithout() throws {
        let with = try JSONDecoder().decode(RemoteAircraftMetadata.self,
                                            from: Data(String(format: meta, #","cruiseSpeedKIAS":105"#).utf8))
        XCTAssertEqual(with.cruiseSpeedKIAS, 105)
        let without = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(String(format: meta, "").utf8))
        XCTAssertNil(without.cruiseSpeedKIAS)
        // A fraction must not throw the whole list away.
        let fraction = try JSONDecoder().decode(RemoteAircraftMetadata.self,
                                                from: Data(String(format: meta, #","cruiseSpeedKIAS":104.5"#).utf8))
        XCTAssertEqual(fraction.cruiseSpeedKIAS, 104.5)
    }

    /// Each tail keeps its own figure through the per-tail split, from the registrations array.
    func testEachTailKeepsItsOwnCruiseSpeed() throws {
        let json = String(format: meta, #"""
        ,"cruiseSpeedKIAS":105,"registrations":[
         {"registration":"HB-KFD","modelName":"DR400","shortModelName":"DR400","version":"1","lastUpdated":"x","cruiseSpeedKIAS":105},
         {"registration":"HB-KFI","modelName":"DR400","shortModelName":"DR400","version":"1","lastUpdated":"x","cruiseSpeedKIAS":100},
         {"registration":"HB-KFX","modelName":"DR400","shortModelName":"DR400","version":"1","lastUpdated":"x"}]
        """#)
        let tails = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(json.utf8)).expandedPerRegistration()
        XCTAssertEqual(tails.map(\.cruiseSpeedKIAS), [105, 100, nil])
    }

    @MainActor
    func testTheStoreReadsTheAircraftsFigureAndThePilotsPerRegistration() throws {
        let store = EETCalibrationStore(defaults: makeTestDefaults())
        let archer = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(String(format: meta, #","cruiseSpeedKIAS":105"#).utf8))
        store.setAircraftCruise(from: [archer])
        XCTAssertEqual(store.cruise(forRegistration: "hb-kfd"), CruiseSpeed(kias: 105, source: .aircraftData))
        store.setManualCruise(["HB-KFD": 98])
        XCTAssertEqual(store.cruise(forRegistration: "HB-KFD"), CruiseSpeed(kias: 98, source: .manual))
        XCTAssertEqual(store.cruise(forRegistration: "F-HVXA"), .standard)
    }

    // MARK: - The pilot's figure in the settings

    func testThePilotsCruiseSpeedIsKeptAndSyncedPerRegistration() throws {
        var settings = AppSettings()
        settings.cruiseSpeedKIAS = ["F-HVXA": 97, "HB-PFA": 900]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).clampedForIngest()
        XCTAssertEqual(decoded.cruiseSpeedKIAS, ["F-HVXA": 97], "a speed no aircraft cruises at is dropped on ingest")
        XCTAssertTrue(AppSettings.protectedFields.contains { $0.key == "cruiseSpeedKIAS" },
                      "an older build relaying the record must not erase it")
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"schemaVersion":6}"#.utf8))
        XCTAssertEqual(older.cruiseSpeedKIAS, [:])
    }
}
