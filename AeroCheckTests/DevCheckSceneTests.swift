import XCTest
import CoreLocation
@testable import AeroCheck

/// `DevCheckScene` (`AEROCHECK_SCENE=devcheck`): the device checks' routes and flights, made through the app's own
/// creation paths, and replaced at each launch without touching anything the pilot made.
final class DevCheckSceneTests: XCTestCase {

    private static func field(_ ident: String, _ latitude: Double, _ longitude: Double, _ country: String) -> Airport {
        Airport(id: abs(ident.hashValue % 100_000), ident: ident, type: .smallAirport, name: ident,
                latitude: latitude, longitude: longitude, elevation: 1_400, continent: "EU", isoCountry: country,
                isoRegion: country, municipality: nil, scheduledService: false, gpsCode: ident, iataCode: nil,
                localCode: nil)
    }

    private struct World {
        let appState: AppState
        let plans: FlightPlanManager
        let threads: FlightThreadManager
        let airports: AirportDataService
        let defaults: UserDefaults
    }

    /// The managers' launch loads landed, as the scene's launch hook waits for them.
    @MainActor
    private func loadedWorld(withAerodromes: Bool = true) async -> World {
        let world = makeWorld(withAerodromes: withAerodromes)
        for _ in 0..<50 where !(world.threads.hasLoadedThreads && world.threads.hasLoadedTrips
                                && world.plans.hasLoadedPlans) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return world
    }

    @MainActor
    private func makeWorld(withAerodromes: Bool) -> World {
        let datastore = makeTestDatastore()
        let airports = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
        if withAerodromes {
            airports.injectForReplay([
                Self.field("LSZQ", 47.3497, 7.0278, "CH"), Self.field("LSZP", 47.1392, 7.2997, "CH"),
                Self.field("LSZG", 47.1820, 7.4170, "CH"), Self.field("EDTF", 48.0228, 7.8325, "DE"),
                Self.field("LFGA", 48.1099, 7.3590, "FR"), Self.field("LFSB", 47.5896, 7.5299, "FR"),
            ])
        }
        return World(appState: makeTestAppState(datastore: datastore), plans: makeTestPlanManager(datastore: datastore),
                     threads: makeTestThreadManager(datastore: datastore), airports: airports,
                     defaults: makeTestDefaults())
    }

    @MainActor
    private func inject(_ world: World) async {
        await DevCheckScene.inject(appState: world.appState, plans: world.plans, threads: world.threads,
                                   airports: world.airports, defaults: world.defaults)
    }

    @MainActor
    func testMakesTheRoutesTheTripAndTodaysFlight() async {
        let world = await loadedWorld()
        let before = FlightClock.now
        await inject(world)

        let routes = world.plans.flightPlans.filter { $0.flightOwned != true }
        XCTAssertEqual(Set(routes.map(\.name)), ["LSZQ → LSZP → LSZG", "LSZQ → EDTF"])
        let viaBiel = routes.first { $0.name == "LSZQ → LSZP → LSZG" }
        XCTAssertEqual(viaBiel?.usualStops.map(\.ident), ["LSZP"])
        XCTAssertEqual(viaBiel?.usualStops.first?.stopover, Stopover(groundMinutes: 45, refuel: true))

        XCTAssertEqual(world.threads.trips.count, 1)
        let legs = world.threads.trips.first.map { world.threads.legs(of: $0) } ?? []
        XCTAssertEqual(legs.map(\.routeLabel), ["LSZQ → LFGA", "LFGA → LSZQ"])
        XCTAssertEqual(legs.map(\.aircraftRegistration), ["F-HVXA", "F-HVXA"])
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: before)!
        let tenTomorrow = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)
        XCTAssertEqual(legs.first?.scheduledDeparture, tenTomorrow)

        let alone = world.threads.threads.filter { $0.tripId == nil }
        XCTAssertEqual(alone.map(\.routeLabel), ["LSZQ → LFSB"])
        let departure = try? XCTUnwrap(alone.first?.scheduledDeparture)
        XCTAssertGreaterThanOrEqual(departure?.timeIntervalSince(before) ?? 0, 2 * 3600)
        XCTAssertLessThan(departure?.timeIntervalSince(before) ?? .infinity, 2 * 3600 + 5 * 60 + 1)
    }

    /// The pilot's own route and flight stay through every launch; the scene's are replaced, never doubled.
    @MainActor
    func testALaunchReplacesOnlyItsOwnItems() async {
        let world = await loadedWorld()
        var own = world.plans.createFlightPlan(name: "LSZQ → LSZG")
        own.waypoints = [FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.3497, longitude: 7.0278)),
                         FlightPlanWaypoint(name: "LSZG", coordinate: .init(latitude: 47.1820, longitude: 7.4170))]
        world.plans.updateFlightPlan(own)
        let ownFlight = world.threads.createThread(from: own, routeLabel: "LSZQ → LSZG",
                                                   aircraftRegistration: "HB-PFA")

        await inject(world)
        let firstIds = Set(world.threads.threads.map(\.id))
        await inject(world)

        XCTAssertNotNil(world.plans.flightPlans.first { $0.id == own.id })
        XCTAssertNotNil(world.threads.thread(withId: ownFlight.id))
        XCTAssertEqual(world.plans.flightPlans.filter { $0.flightOwned != true }.count, 3)
        XCTAssertEqual(world.threads.threads.count, 4)
        XCTAssertEqual(world.threads.trips.count, 1)
        XCTAssertEqual(Set(world.threads.threads.map(\.id)).intersection(firstIds), [ownFlight.id])
    }

    /// No airport data: nothing resolves, so nothing is made, and the last launch's items are gone all the same.
    @MainActor
    func testWithoutAerodromesNothingIsMade() async {
        let world = await loadedWorld(withAerodromes: false)
        await inject(world)
        XCTAssertTrue(world.plans.flightPlans.isEmpty)
        XCTAssertTrue(world.threads.threads.isEmpty)
    }
}
