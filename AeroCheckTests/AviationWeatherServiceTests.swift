import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for the aviation-weather proxy client: the coordinate grid applied before a position
/// leaves the device, and the decode contract against the proxy's normalised response shape.
///
/// The grid earns tests for two independent reasons, and both are asserted below.
///
/// It is a PRIVACY boundary. A METAR/SIGMET refresh runs on a timer for as long as a briefing is
/// open, so a full-precision fix in a query string writes a live flight track into edge request
/// logs — the one place a coordinate is least protected, since a query string survives in logs
/// long after the response is gone.
///
/// It is also a PARITY contract. The worker snaps every incoming coordinate to the same 0.25° grid
/// (`GRID_DEGREES` in `AeroCheck-server/workers/weather/src/lib.ts`) before it builds a cache key,
/// an upstream URL, or a distance sort. Snapping client-side is therefore a no-op on the response
/// rather than an approximation of it — but only for as long as the two grids agree, which is what
/// makes this worth a test rather than a comment.
///
/// The decode tests exist because `Metar`/`Taf`/`Sigmet` mirror types that live in a DIFFERENT
/// repository. Nothing in the build catches a rename on the worker side; these fixtures are copied
/// from `workers/weather/src/aviation.ts` and fail loudly if the shapes drift apart.
final class AviationWeatherServiceTests: XCTestCase {

    /// The worker's `GRID_DEGREES`, written as a literal on purpose: deriving it from the constant
    /// under test would make every assertion here tautological.
    private let workerGridDegrees = 0.25

    /// Matches the service's own private decoder. The proxy emits ISO-8601 timestamps.
    private func proxyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Coordinate snapping

    func testSnapQuantizesToTheWorkerGrid() {
        XCTAssertEqual(AviationWeatherService.snap(46.51), 46.50, accuracy: 1e-9)
        XCTAssertEqual(AviationWeatherService.snap(46.63), 46.75, accuracy: 1e-9)
        XCTAssertEqual(AviationWeatherService.snap(46.87), 46.75, accuracy: 1e-9)
        XCTAssertEqual(AviationWeatherService.snap(46.94), 47.00, accuracy: 1e-9)
    }

    /// Rounding toward zero instead of to nearest would bias every southern/western position one
    /// cell inward, which is exactly the kind of error a Switzerland-only test set never catches.
    func testSnapHandlesSouthernAndWesternHemispheres() {
        XCTAssertEqual(AviationWeatherService.snap(-33.94), -34.00, accuracy: 1e-9)
        XCTAssertEqual(AviationWeatherService.snap(-118.41), -118.50, accuracy: 1e-9)
    }

    /// The property that makes client-side snapping safe to add at all: the worker snaps again on
    /// receipt, and snapping an already-snapped value must change nothing. If it did, the two
    /// rounding passes would disagree and the response would shift relative to today's behaviour.
    func testSnapIsIdempotent() {
        for raw in stride(from: -180.0, through: 180.0, by: 3.7) {
            let once = AviationWeatherService.snap(raw)
            XCTAssertEqual(AviationWeatherService.snap(once), once, accuracy: 1e-9,
                           "snapping twice must equal snapping once for \(raw)")
        }
    }

    /// Both weather clients answer to the same worker constant, and therefore to each other. Drift
    /// here would mean two services caching one position under two different cells.
    func testSnapAgreesWithWindsAloftGrid() {
        for raw in [46.516_234_891_2, -0.127_758_3, 89.9, -179.87, 0.0] {
            XCTAssertEqual(AviationWeatherService.snap(raw),
                           WindsAloftService.snap(raw), accuracy: 1e-9,
                           "grid disagreement at \(raw)")
        }
    }

    /// The privacy property stated as an assertion: a full-precision live fix must not survive into
    /// the query string. These are the LSGG (Geneva) threshold coordinates to ~10 cm.
    func testSnapDiscardsLiveFixPrecision() {
        let fix = CLLocationCoordinate2D(latitude: 46.238_092_447_1, longitude: 6.109_551_882_3)
        XCTAssertEqual(AviationWeatherService.snap(fix.latitude), 46.25, accuracy: 1e-9)
        XCTAssertEqual(AviationWeatherService.snap(fix.longitude), 6.00, accuracy: 1e-9)
    }

    /// Worst case is half a cell, ~7.5 nm of latitude — an order of magnitude inside the 60 nm
    /// METAR radius and two inside the 150 nm SIGMET radius, so the coarsening cannot change which
    /// stations or hazards come back.
    func testSnapDisplacementStaysWithinHalfACell() {
        for raw in stride(from: -90.0, through: 90.0, by: 1.3) {
            let delta = abs(AviationWeatherService.snap(raw) - raw)
            XCTAssertLessThanOrEqual(delta, workerGridDegrees / 2 + 1e-9,
                                     "snap moved \(raw) by \(delta)°, more than half a cell")
        }
    }

    // MARK: - METAR decode contract

    private let metarJSON = """
    {
      "icao": "LSGG", "name": "Geneva Cointrin", "lat": 46.2381, "lon": 6.1089,
      "elevationM": 411, "distanceNm": 3.4,
      "windDirectionDeg": 240, "windVariable": false, "windSpeedKt": 12, "windGustKt": 22,
      "temperatureC": 18.0, "dewpointC": 11.0, "altimeterHpa": 1017.0,
      "flightCategory": "VFR", "observedAt": "2026-08-15T12:20:00Z",
      "raw": "LSGG 151220Z 24012G22KT 9999 FEW040 18/11 Q1017"
    }
    """

    func testMetarDecodesTheProxyShape() throws {
        let metar = try proxyDecoder().decode(
            AviationWeatherService.Metar.self, from: Data(metarJSON.utf8))

        XCTAssertEqual(metar.icao, "LSGG")
        XCTAssertEqual(metar.distanceNm, 3.4, accuracy: 1e-9)
        XCTAssertEqual(metar.windDirectionDeg, 240)
        XCTAssertFalse(metar.windVariable)
        XCTAssertEqual(metar.windGustKt, 22)
        XCTAssertEqual(metar.flightCategory, "VFR")
        XCTAssertNotNil(metar.observedAt)
        XCTAssertEqual(metar.id, metar.icao, "identity is the station, so SwiftUI reuses its row")
    }

    /// VRB and "wind missing" are different facts and the service's own doc comment says they are
    /// not interchangeable: the worker nulls `windDirectionDeg` and raises `windVariable`. A client
    /// that collapsed the two would draw a confident arrow at 0° for a variable wind.
    func testVariableWindIsDistinctFromAbsentWind() throws {
        let variable = """
        {"icao":"LSZH","name":null,"lat":47.46,"lon":8.55,"elevationM":432,"distanceNm":9.1,
         "windDirectionDeg":null,"windVariable":true,"windSpeedKt":3,"windGustKt":null,
         "temperatureC":16.0,"dewpointC":12.0,"altimeterHpa":1016.0,"flightCategory":"VFR",
         "observedAt":"2026-08-15T12:20:00Z","raw":"LSZH 151220Z VRB03KT"}
        """
        let calm = """
        {"icao":"LSZB","name":null,"lat":46.91,"lon":7.50,"elevationM":510,"distanceNm":21.7,
         "windDirectionDeg":null,"windVariable":false,"windSpeedKt":null,"windGustKt":null,
         "temperatureC":17.0,"dewpointC":10.0,"altimeterHpa":1016.0,"flightCategory":null,
         "observedAt":null,"raw":null}
        """
        let decoder = proxyDecoder()
        let vrb = try decoder.decode(AviationWeatherService.Metar.self, from: Data(variable.utf8))
        let none = try decoder.decode(AviationWeatherService.Metar.self, from: Data(calm.utf8))

        XCTAssertNil(vrb.windDirectionDeg)
        XCTAssertTrue(vrb.windVariable, "VRB must survive as variable, not as a missing direction")
        XCTAssertNil(none.windDirectionDeg)
        XCTAssertFalse(none.windVariable, "no direction reported is not the same as VRB")
        XCTAssertNil(none.observedAt, "a null timestamp is legal and must not fail the payload")
    }

    /// The worker normalises AWC's mixed epoch/string times through `isoTime`, and
    /// `new Date(...).toISOString()` always emits milliseconds while a passed-through AWC string
    /// does not. Both forms reach the client, so both must decode — a strategy that rejected
    /// fractional seconds would silently drop every observation whose time came from an epoch.
    func testObservedAtDecodesBothTimestampFormsTheWorkerEmits() throws {
        let decoder = proxyDecoder()
        for stamp in ["2026-08-15T12:20:00Z", "2026-08-15T12:20:00.000Z"] {
            let json = metarJSON.replacingOccurrences(
                of: "\"2026-08-15T12:20:00Z\"", with: "\"\(stamp)\"")
            let metar = try decoder.decode(
                AviationWeatherService.Metar.self, from: Data(json.utf8))
            XCTAssertEqual(metar.observedAt?.timeIntervalSince1970, 1_786_796_400,
                           "\(stamp) must decode to the same instant")
        }
    }

    // MARK: - SIGMET decode contract

    func testSigmetDecodesAndExposesItsPolygon() throws {
        let json = """
        {"firId":"LSAS","firName":"SWITZERLAND","hazard":"TURB","qualifier":"SEV",
         "baseFt":10000,"topFt":24000,
         "validFrom":"2026-08-15T12:00:00Z","validTo":"2026-08-15T16:00:00Z",
         "distanceNm":42.5,"containsPoint":false,
         "coords":[{"lat":46.5,"lon":6.5},{"lat":47.0,"lon":7.0},{"lat":46.8,"lon":8.0}],
         "raw":"LSAS SIGMET 1 VALID 151200/151600"}
        """
        let sigmet = try proxyDecoder().decode(
            AviationWeatherService.Sigmet.self, from: Data(json.utf8))

        XCTAssertEqual(sigmet.hazard, "TURB")
        XCTAssertEqual(sigmet.baseFt, 10_000)
        XCTAssertFalse(sigmet.containsPoint)

        // The polygon is the whole point of carrying `coords`: distance can be recomputed locally
        // as the aircraft moves, instead of the fetch-time figure reading 42 nm all the way in.
        XCTAssertEqual(sigmet.ring.count, 3)
        XCTAssertEqual(sigmet.ring.first?.latitude ?? 0, 46.5, accuracy: 1e-9)
        XCTAssertEqual(sigmet.ring.first?.longitude ?? 0, 6.5, accuracy: 1e-9)
    }

    /// Identity is composed from FIR + hazard + validity because a SIGMET carries no id of its own,
    /// and two hazards for one FIR are routine. Collapsing them would hide one from the briefing.
    func testSigmetIdentityDistinguishesConcurrentHazards() throws {
        func sigmet(hazard: String) throws -> AviationWeatherService.Sigmet {
            let json = """
            {"firId":"LSAS","firName":"SWITZERLAND","hazard":"\(hazard)","qualifier":"SEV",
             "baseFt":null,"topFt":null,
             "validFrom":"2026-08-15T12:00:00Z","validTo":"2026-08-15T16:00:00Z",
             "distanceNm":10.0,"containsPoint":true,"coords":[],"raw":null}
            """
            return try proxyDecoder().decode(
                AviationWeatherService.Sigmet.self, from: Data(json.utf8))
        }
        let turbulence = try sigmet(hazard: "TURB")
        let ice = try sigmet(hazard: "ICE")

        XCTAssertNotEqual(turbulence.id, ice.id,
                          "two concurrent hazards in one FIR must remain separate rows")
        XCTAssertTrue(turbulence.ring.isEmpty, "an empty polygon is legal, not a decode failure")
    }

    // MARK: - TAF decode contract

    func testTafDecodesItsForecastPeriods() throws {
        let json = """
        {"icao":"LSGG","forecasts":[
          {"icao":"LSGG","issuedAt":"2026-08-15T11:00:00Z","validFrom":"2026-08-15T12:00:00Z",
           "validTo":"2026-08-16T12:00:00Z","raw":"TAF LSGG 151100Z 1512/1612 24010KT"},
          {"icao":"LSGG","issuedAt":null,"validFrom":null,"validTo":null,"raw":null}
        ]}
        """
        let taf = try proxyDecoder().decode(
            AviationWeatherService.Taf.self, from: Data(json.utf8))

        XCTAssertEqual(taf.icao, "LSGG")
        XCTAssertEqual(taf.forecasts.count, 2)
        XCTAssertNotNil(taf.forecasts[0].validFrom)
        XCTAssertNil(taf.forecasts[1].validFrom, "a sparse period must not fail the whole TAF")
    }
}
