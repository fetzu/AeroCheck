import XCTest
@testable import AeroCheck

/// Tests the logbook "favorite" flag: it must survive a Codable round-trip, default to `false` for
/// legacy records that predate the field, and toggling it through `AppState` must flip the flag and
/// stamp `modifiedAt` so the star rides CloudKit's conflict tiebreaker. (3.3 favorites)
@MainActor
final class FlightFavoriteTests: XCTestCase {

    // MARK: - Codable

    func testIsFavoriteSurvivesEncodeDecode() throws {
        var flight = Flight(name: "Pinned hop")
        flight.isFavorite = true

        let data = try JSONEncoder().encode(flight)
        let decoded = try JSONDecoder().decode(Flight.self, from: data)

        XCTAssertTrue(decoded.isFavorite, "isFavorite must round-trip through Codable")
    }

    func testLegacyRecordWithoutFieldDecodesToFalse() throws {
        // A minimal v1-era record that predates `isFavorite` must decode without throwing and
        // default the flag to false.
        let legacyJSON = """
        { "id": "\(UUID().uuidString)", "airplane": "wt9-dynamic", "gpsTrack": [], "notes": "",
          "goAroundCount": 0, "touchAndGoCount": 0, "goAroundTimes": [], "touchAndGoTimes": [] }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Flight.self, from: legacyJSON)

        XCTAssertFalse(decoded.isFavorite, "A record without the key must default isFavorite to false")
    }

    func testNewFlightDefaultsToNotFavorite() {
        XCTAssertFalse(Flight().isFavorite, "Flights start un-favorited")
    }

    // MARK: - AppState toggle

    func testToggleFavoriteFlipsTheFlag() {
        let appState = AppState()
        let flight = Flight(name: "Toggle me")
        appState.flights = [flight]

        appState.toggleFavorite(flight)
        XCTAssertTrue(appState.flights[0].isFavorite, "First toggle favorites the flight")

        appState.toggleFavorite(flight)
        XCTAssertFalse(appState.flights[0].isFavorite, "Second toggle un-favorites it")
    }

    func testToggleFavoriteStampsModifiedAt() {
        let appState = AppState()
        let old = Date(timeIntervalSince1970: 0)
        var flight = Flight(name: "Stamp me")
        flight.modifiedAt = old
        appState.flights = [flight]

        appState.toggleFavorite(flight)

        XCTAssertGreaterThan(appState.flights[0].modifiedAt, old,
                             "Toggling must bump modifiedAt for CloudKit conflict resolution")
    }

    func testToggleUnknownFlightIsANoOp() {
        let appState = AppState()
        appState.flights = [Flight(name: "Present")]

        appState.toggleFavorite(Flight(name: "Absent")) // different id, not in the list

        XCTAssertFalse(appState.flights[0].isFavorite, "Toggling a flight not in the log changes nothing")
        XCTAssertEqual(appState.flights.count, 1)
    }
}
