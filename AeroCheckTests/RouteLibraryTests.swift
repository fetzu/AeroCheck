import XCTest
import CoreLocation
@testable import AeroCheck

/// The Routes list: which plans are routes, what the search finds, archiving, renaming, and a
/// renamed route's files. (on-device review #4)
@MainActor
final class RouteLibraryTests: XCTestCase {

    private func plan(_ name: String = "", _ idents: [String] = ["LSZS", "LSZQ"], created: Date = Date()) -> FlightPlan {
        var plan = FlightPlan(name: name)
        plan.waypoints = idents.enumerated().map { index, ident in
            FlightPlanWaypoint(name: ident, coordinate: CLLocationCoordinate2D(latitude: 46.5 + Double(index) * 0.1,
                                                                               longitude: 9.8 - Double(index) * 0.1))
        }
        plan.createdAt = created
        return plan
    }

    // MARK: - What is a route (R1)

    func testAFlightsOwnPlanIsNotARoute() {
        var copy = plan()
        copy.flightOwned = true
        XCTAssertFalse(RouteLibrary.isRoute(copy, followedSince: nil))
    }

    func testAPlanNoFlightFollowsIsARoute() {
        XCTAssertTrue(RouteLibrary.isRoute(plan(), followedSince: nil))
    }

    /// Plans saved before the mark: made together with their flight (Plan new flight, Add a stop)
    /// they are the flight's; a route followed later from Routes stays a route.
    func testALegacyPlanMadeWithItsFlightIsTheFlights() {
        let made = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(RouteLibrary.isRoute(plan(created: made), followedSince: made.addingTimeInterval(1)))
        XCTAssertTrue(RouteLibrary.isRoute(plan(created: made), followedSince: made.addingTimeInterval(86_400)),
                      "Follow flight on a route made days before: still the pilot's route")
    }

    // MARK: - Search

    func testTheSearchFindsNamesWaypointsAndAircraftIgnoringCaseAndAccents() {
        var route = plan("Samedan - Bressaucourt", ["Samedan", "Bergün", "LSZQ"])
        route.aircraftRegistration = "F-HVXA"
        XCTAssertTrue(RouteLibrary.matches(route, query: "bress"))
        XCTAssertTrue(RouteLibrary.matches(route, query: "BERGUN"), "accents ignored")
        XCTAssertTrue(RouteLibrary.matches(route, query: "lszq samedan"), "every word, in any order")
        XCTAssertTrue(RouteLibrary.matches(route, query: "hvxa"))
        XCTAssertTrue(RouteLibrary.matches(route, query: "  "), "an empty search keeps everything")
        XCTAssertFalse(RouteLibrary.matches(route, query: "lsgy"))
        XCTAssertFalse(RouteLibrary.matches(route, query: "samedan lsgy"))
    }

    // MARK: - Archive and rename

    func testArchivingKeepsTheRouteAndUnarchivingBringsItBack() {
        let manager = makeTestPlanManager()
        let route = plan("Local")
        manager.add(route)
        manager.archive(route)
        XCTAssertNotNil(manager.flightPlans.first { $0.id == route.id }?.archivedAt)
        manager.unarchive(route)
        XCTAssertNil(manager.flightPlans.first { $0.id == route.id }?.archivedAt)
    }

    func testArchivingTheRouteOnTheMapTakesItOffTheMap() {
        let manager = makeTestPlanManager()
        let route = plan("Local")
        manager.add(route)
        manager.activateFlightPlan(route)
        XCTAssertEqual(manager.activeFlightPlan?.id, route.id)
        manager.archive(route)
        XCTAssertNil(manager.activeFlightPlan)
    }

    func testRenamingTrimsAndEmptyClears() {
        let manager = makeTestPlanManager()
        let route = plan("Samedan - Bressaucourt")
        manager.add(route)
        manager.rename(route, to: "  Home via the Rhine valley ")
        XCTAssertEqual(manager.flightPlans.first { $0.id == route.id }?.name, "Home via the Rhine valley")
        manager.rename(route, to: "   ")
        XCTAssertEqual(manager.flightPlans.first { $0.id == route.id }?.name, "")
    }

    func testTheNewFieldsRoundTripAndOldPlansDecodeWithout() throws {
        var route = plan()
        route.archivedAt = Date(timeIntervalSince1970: 1_790_000_000)
        route.flightOwned = true
        let decoded = try JSONDecoder().decode(FlightPlan.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded.archivedAt, route.archivedAt)
        XCTAssertEqual(decoded.flightOwned, true)

        let old = try JSONDecoder().decode(FlightPlan.self, from: JSONEncoder().encode(plan()))
        XCTAssertNil(old.archivedAt)
        XCTAssertNil(old.flightOwned)
    }

    func testACopyStaysTheFlightsButIsntArchived() {
        var original = plan()
        original.flightOwned = true
        original.archivedAt = Date()
        let copy = original.copy()
        XCTAssertEqual(copy.flightOwned, true, "a leg split off a flight's plan is that flight's too")
        XCTAssertNil(copy.archivedAt)
    }

    // MARK: - A renamed route's files

    /// A plan's file is named after it: renamed, it used to leave its old file behind, and deleting
    /// it then brought the route back from that file on the next launch.
    func testRenamingLeavesOneFileAndDeletingLeavesNone() throws {
        let directory = makeTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var route = plan("Alpha")
        DataPersistenceManager.writeNavigationPlanFiles([route], index: [route], to: directory)
        route.name = "Beta"
        DataPersistenceManager.writeNavigationPlanFiles([route], index: [route], to: directory)

        let jsons = { try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && $0 != "plans_index.json" } }
        XCTAssertEqual(try jsons(), [DataPersistenceManager.navigationPlanFilename(for: route)])

        DataPersistenceManager.deleteNavigationPlanFiles(for: route, in: directory)
        XCTAssertEqual(try jsons(), [])
    }

    func testDeletingFindsTheFileTheIndexRecorded() throws {
        let directory = makeTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var route = plan("Alpha")
        DataPersistenceManager.writeNavigationPlanFiles([route], index: [route], to: directory)
        route.name = "Renamed but never saved"
        DataPersistenceManager.deleteNavigationPlanFiles(for: route, in: directory)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && $0 != "plans_index.json" }
        XCTAssertEqual(left, [])
    }

    // MARK: - SkyDemon import: ICAO codes for place names

    /// The shape of SkyDemon's export: aerodromes named after their place, the code in `<sym>`;
    /// published points unnamed with their ident in `<sym>`.
    private let skyDemonGPX = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <gpx xmlns:skd="http://www.skydemon.aero/gpxextensions" version="1.1" creator="SkyDemon for iPad" xmlns="http://www.topografix.com/GPX/1/1">
      <rte>
        <name>Samedan - Bressaucourt</name>
        <rtept lat="46.534443" lon="9.883889"><ele>1702</ele><name>Samedan</name><sym>LSZS</sym>
          <extensions><skd:level type="A" value="11600" /></extensions></rtept>
        <rtept lat="46.574722" lon="9.921945"><ele>1686</ele><name /><sym>E</sym>
          <extensions><skd:level type="A" value="12100" /></extensions></rtept>
        <rtept lat="47.015" lon="9.4819"><ele>492</ele><name>Bad Ragaz</name><sym>LSZE</sym>
          <extensions><skd:level type="A" value="5000" /></extensions></rtept>
        <rtept lat="47.1333" lon="9.2333"><ele>680</ele><name>Walenstadt</name>
          <extensions><skd:level type="A" value="5000" /></extensions></rtept>
        <rtept lat="47.392502" lon="7.028889"><ele>565</ele><name>Bressaucourt</name><sym>LSZQ</sym><extensions /></rtept>
      </rte>
    </gpx>
    """.utf8)

    func testTheFileGivesTheCodesOfItsPlaceNames() throws {
        let (plan, idents) = try XCTUnwrap(FlightPlan.fromGPXWithIdents(skyDemonGPX))
        XCTAssertEqual(plan.waypoints.map(\.name), ["Samedan", "E", "Bad Ragaz", "Walenstadt", "Bressaucourt"])
        XCTAssertEqual(plan.waypoints.compactMap { idents[$0.id] }, ["LSZS", "LSZE", "LSZQ"],
                       "a reporting point's ident is already its name; a place without a code has none")
    }

    func testTheOfferListsEachPlaceWithItsCode() throws {
        let (plan, idents) = try XCTUnwrap(FlightPlan.fromGPXWithIdents(skyDemonGPX))
        let offer = ICAONaming.suggestions(for: plan, fileIdents: idents) { _ in nil }
        XCTAssertEqual(offer.map { "\($0.number) \($0.name) → \($0.ident)" },
                       ["1 Samedan → LSZS", "3 Bad Ragaz → LSZE", "5 Bressaucourt → LSZQ"])
    }

    /// A route imported before the codes were kept: the aerodrome under the waypoint gives it.
    func testWithoutTheFilesCodesTheAerodromeUnderneathGivesThem() throws {
        let (plan, _) = try XCTUnwrap(FlightPlan.fromGPXWithIdents(skyDemonGPX))
        let offer = ICAONaming.suggestions(for: plan, fileIdents: [:]) { coordinate in
            coordinate.latitude > 47.3 ? "LSZQ" : nil
        }
        XCTAssertEqual(offer.map(\.ident), ["LSZQ"])
        XCTAssertTrue(ICAONaming.suggestions(for: plan, fileIdents: [:]) { _ in "ABC" }.isEmpty,
                      "only a 4-letter ICAO code is offered")
    }

    func testApplyingKeepsThePlaceNameInTheRemarks() throws {
        var (plan, idents) = try XCTUnwrap(FlightPlan.fromGPXWithIdents(skyDemonGPX))
        plan.waypoints[2].remarks = "Heliport nearby"
        let offer = ICAONaming.suggestions(for: plan, fileIdents: idents) { _ in nil }
        let renamed = ICAONaming.apply(offer.filter { $0.ident != "LSZE" }, to: plan)
        XCTAssertEqual(renamed.waypoints.map(\.name), ["LSZS", "E", "Bad Ragaz", "Walenstadt", "LSZQ"],
                       "only the codes chosen")
        XCTAssertEqual(renamed.waypoints[0].remarks, "Samedan")
        XCTAssertEqual(renamed.waypoints[2].remarks, "Heliport nearby", "existing remarks are left alone")
    }

    /// A GPX file carries no aircraft: an imported route is planned for the selected one, not the
    /// parser's F-HVXA.
    func testAnImportedRouteTakesTheSelectedAircraft() throws {
        let manager = makeTestPlanManager()
        let aircraft = FlightPlanManager.RouteAircraft(typeId: "PA28", registration: "HB-PFA", modelName: "Piper Archer II")
        let (plan, idents) = try XCTUnwrap(manager.importRoute(from: skyDemonGPX, aircraft: aircraft))
        XCTAssertEqual(plan.aircraftRegistration, "HB-PFA")
        XCTAssertEqual(plan.aircraftTypeId, "PA28")
        XCTAssertEqual(plan.fuelFlow, FlightPlan.defaultFuelFlow(for: "PA28"))
        XCTAssertEqual(idents.count, 3)
        XCTAssertEqual(manager.flightPlans.first?.id, plan.id)
    }
}

