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
}
