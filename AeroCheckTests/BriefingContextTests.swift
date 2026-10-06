import XCTest
import CoreLocation
@testable import AeroCheck

/// `BriefingContextBuilder`: which aerodromes the briefing is about.
final class BriefingContextTests: XCTestCase {

    private static func field(_ ident: String, _ latitude: Double, _ longitude: Double) -> Airport {
        Airport(id: abs(ident.hashValue % 100_000), ident: ident, type: .smallAirport, name: ident,
                latitude: latitude, longitude: longitude, elevation: 1_500, continent: "EU", isoCountry: "CH",
                isoRegion: "CH", municipality: nil, scheduledService: false, gpsCode: ident, iataCode: nil,
                localCode: nil)
    }

    @MainActor
    private func airports() -> AirportDataService {
        let store = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
        store.injectForReplay([Self.field("LSGC", 47.0839, 6.7928), Self.field("LSZQ", 47.3923, 7.0296)])
        return store
    }

    @MainActor
    private func build(at location: CLLocationCoordinate2D?, plan: FlightPlan?, airports: AirportDataService) -> BriefingContext {
        BriefingContextBuilder.build(speeds: [], hasParachute: false, aircraftRegistration: "HB-ABC",
                                     aircraftType: "WT9", currentLocation: location, airportDataService: airports,
                                     flightPlan: plan)
    }

    private static let fromLSGC = FlightPlan(name: "LSGC - LSZQ", waypoints: [
        FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.0839, longitude: 6.7928)),
        FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.3923, longitude: 7.0296)),
    ])

    /// A flight from LSGC started far from it (planned at home in Tinizong): the briefing used to say
    /// "Airport: Not detected", as it only looked under the aircraft (device check, 6 Oct). The plan's
    /// departure now; the field under the aircraft still wins where there is one.
    @MainActor
    func testTheDepartureIsTheFieldBelowElseThePlans() {
        let store = airports()
        let tinizong = CLLocationCoordinate2D(latitude: 46.582, longitude: 9.616)
        XCTAssertEqual(build(at: tinizong, plan: Self.fromLSGC, airports: store).departureAirport?.ident, "LSGC")
        XCTAssertEqual(build(at: nil, plan: Self.fromLSGC, airports: store).departureAirport?.ident, "LSGC", "no fix yet")
        let atBressaucourt = CLLocationCoordinate2D(latitude: 47.392, longitude: 7.03)
        XCTAssertEqual(build(at: atBressaucourt, plan: Self.fromLSGC, airports: store).departureAirport?.ident, "LSZQ",
                       "where the aircraft is wins")
        XCTAssertNil(build(at: tinizong, plan: nil, airports: store).departureAirport, "no plan, nothing below")
    }
}
