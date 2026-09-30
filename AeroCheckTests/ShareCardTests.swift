import XCTest
import CoreLocation
@testable import AeroCheck

/// The flight share card's figures: the minute rule, the number format, units, time zones, counts,
/// the credit line and the French labels. `ShareCardFigures` is pure, so none of this renders a view
/// or touches a service. (6.1)
final class ShareCardTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private let swiss = Locale(identifier: "en_CH")
    /// Switzerland's thousands mark, whichever apostrophe this ICU gives it.
    private var mark: String { swiss.groupingSeparator ?? "’" }
    private let zurich = TimeZone(identifier: "Europe/Zurich")!

    private func figures(_ flight: Flight, nauticalMiles: Bool = true, useUTC: Bool = false,
                         locale: Locale? = nil) -> ShareCardFigures {
        ShareCardFigures(flight: flight, nauticalMiles: nauticalMiles, useUTC: useUTC,
                         locale: locale ?? swiss, localTimeZone: zurich)
    }

    /// 29 Sep 2026, leg 3 (LSGN → LSZQ) as recorded: take-off 14:18:33, landing 14:44:17 local.
    private func leg3() -> Flight {
        var flight = Flight(airplane: "wt9-dynamic", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        flight.blockOffTime = date("2026-09-29T12:11:05Z")
        flight.lineUpTime = date("2026-09-29T12:18:33Z")
        flight.landingTime = date("2026-09-29T12:44:17Z")
        flight.blockOnTime = date("2026-09-29T12:45:40Z")
        flight.engineStartTime = date("2026-09-29T12:08:00Z")
        flight.engineShutdownTime = date("2026-09-29T12:46:30Z")
        flight.startTime = date("2026-09-29T12:06:00Z")
        flight.stopTime = date("2026-09-29T12:47:00Z")
        flight.fullStopCount = 1
        flight.fullStopTimes = [flight.landingTime!]
        return flight
    }

    // MARK: - The duration beside the title (B1)

    /// The card printed "0h25" beside 14:18 → 14:44: it truncated the exact 25 min 44 s. The logbook
    /// writes 0:26, and so does the card now.
    func testFlightTimeFollowsTheMinuteRule() {
        let figures = figures(leg3())
        XCTAssertEqual(figures.headline, .init(kind: .flight, minutes: 26))
        XCTAssertEqual(figures.headlineValue, "0:26")
        XCTAssertEqual(figures.headlineLabel, L10n.ShareCard.flightTime)
        XCTAssertEqual(figures.time(leg3().lineUpTime!), "14:18")
        XCTAssertEqual(figures.time(leg3().landingTime!), "14:44")
    }

    /// 23 Sep: 10:46:51 → 12:26:06 was "1h39" on the card, 1:40 in the logbook.
    func testALongFlightReadsHoursAndMinutesLikeTheLogbook() {
        var flight = leg3()
        flight.lineUpTime = date("2026-09-23T08:46:51Z")
        flight.landingTime = date("2026-09-23T10:26:06Z")
        XCTAssertEqual(figures(flight).headlineValue, "1:40")
        XCTAssertEqual(figures(flight).headlineValue, LogbookLineBuilder.formatMinutes(flight.flightMinutes!))
    }

    func testDurationFormatIsHoursColonMinutes() {
        XCTAssertEqual(ShareCardFigures.formattedDuration(minutes: 0), "0:00")
        XCTAssertEqual(ShareCardFigures.formattedDuration(minutes: 59), "0:59")
        XCTAssertEqual(ShareCardFigures.formattedDuration(minutes: 605), "10:05")
        XCTAssertEqual(ShareCardFigures.formattedDuration(minutes: -5), "0:00")
    }

    /// No landing: the card shows the block time and says so, rather than calling a take-off to
    /// block-on interval "FLIGHT TIME".
    func testWithoutALandingTheCardShowsTheBlockTimeByName() {
        var flight = leg3()
        flight.landingTime = nil
        let figures = figures(flight)
        XCTAssertEqual(figures.headline, .init(kind: .block, minutes: 34))   // 14:11 → 14:45
        XCTAssertEqual(figures.headlineLabel, L10n.ShareCard.blockTime)
    }

    func testWithoutTakeOffOrBlockTimesTheCardFallsBackToTheEngineThenTheRecording() {
        var flight = leg3()
        flight.lineUpTime = nil
        flight.blockOffTime = nil
        XCTAssertEqual(figures(flight).headline, .init(kind: .engine, minutes: 38))   // 14:08 → 14:46
        XCTAssertEqual(figures(flight).headlineLabel, L10n.ShareCard.engineTime)

        flight.engineShutdownTime = nil
        XCTAssertEqual(figures(flight).headline, .init(kind: .session, minutes: 41))  // 14:06 → 14:47
        XCTAssertEqual(figures(flight).headlineLabel, L10n.ShareCard.sessionTime)

        flight.stopTime = nil
        XCTAssertNil(figures(flight).headline)
        XCTAssertEqual(figures(flight).headlineValue, "--:--")
    }

    /// Times out of order are skipped, never printed negative.
    func testAnIntervalOutOfOrderIsSkippedNotShownNegative() {
        var flight = leg3()
        flight.landingTime = date("2026-09-29T12:10:00Z")    // before the take-off
        XCTAssertEqual(figures(flight).headline?.kind, .block)

        flight.blockOnTime = date("2026-09-29T12:00:00Z")    // before the block off
        flight.engineShutdownTime = date("2026-09-29T12:00:00Z")
        flight.stopTime = date("2026-09-29T12:00:00Z")
        XCTAssertNil(figures(flight).headline)
    }

    // MARK: - Numbers and units (B2, B14)

    /// One format for every figure: the region's grouping, and "ft" in lower case everywhere.
    func testEveryFigureUsesTheRegionsGrouping() {
        var flight = leg3()
        flight.cachedMaxAltitudeMeters = 5688 / 3.28084
        flight.cachedDistanceKm = 1234.4
        let swiss = figures(flight, nauticalMiles: false)
        XCTAssertEqual(swiss.maxAltitude, "5\(mark)688 ft")
        XCTAssertEqual(L10n.ShareCard.peak(swiss.maxAltitude!), "PEAK 5\(mark)688 ft")
        XCTAssertEqual(swiss.distance, "1\(mark)234 km")
        XCTAssertEqual(swiss.number(12_345), "12\(mark)345")
        XCTAssertTrue(["'", "’"].contains(mark), "an apostrophe, as the Swiss write it")

        let american = figures(flight, nauticalMiles: false, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(american.maxAltitude, "5,688 ft")
        XCTAssertEqual(american.distance, "1,234 km")
    }

    /// The flight's page and the card show the same maximum: the track's highest fix, rounded
    /// (the card used to truncate it).
    func testMaxAltitudeIsRoundedLikeTheFlightsPage() {
        var flight = leg3()
        flight.gpsTrack = [GPSPoint(latitude: 47, longitude: 7, altitude: 1733.9),
                           GPSPoint(latitude: 47, longitude: 7, altitude: 500)]
        XCTAssertEqual(figures(flight).maxAltitudeFeet, 5689)     // 5688.7 ft
        XCTAssertEqual(figures(flight).maxAltitude, "5\(mark)689 ft")
        XCTAssertEqual(FlightDetailView.maxAltitudeText(for: flight), "5689 ft")
    }

    /// The distance follows Settings, as in the Logbook: it was NM whatever the pilot chose.
    func testDistanceFollowsTheSettingsUnit() {
        var flight = leg3()
        flight.cachedDistanceKm = 71.9
        XCTAssertEqual(figures(flight, nauticalMiles: true).distance, "39 NM")
        XCTAssertEqual(figures(flight, nauticalMiles: false).distance, "72 km")
        XCTAssertEqual(figures(flight, nauticalMiles: true).distance,
                       FlightDetailView.distanceText(for: flight, nauticalMiles: true))
        XCTAssertEqual(figures(flight, nauticalMiles: false).distance,
                       FlightDetailView.distanceText(for: flight, nauticalMiles: false))

        flight.cachedDistanceKm = 1.5
        XCTAssertEqual(figures(flight, nauticalMiles: true).distance, "0.8 NM")
        XCTAssertEqual(figures(flight, nauticalMiles: true, locale: Locale(identifier: "fr_FR")).distance, "0,8 NM")
    }

    // MARK: - Time zone (B15)

    func testTimesSayWhetherTheyAreLocalOrUTC() {
        let flight = leg3()
        let local = figures(flight, useUTC: false)
        XCTAssertEqual(local.time(flight.lineUpTime!), "14:18")
        XCTAssertEqual(local.timeZoneLabel, L10n.ShareCard.localTime)
        XCTAssertEqual(local.timeZoneLabel, "LT")

        let utc = figures(flight, useUTC: true)
        XCTAssertEqual(utc.time(flight.lineUpTime!), "12:18")
        XCTAssertEqual(utc.timeZoneLabel, "UTC")
    }

    // MARK: - Counts (B6, B7)

    /// A go-around used to hide the touch-and-goes (13 Feb, "Vol 4.4": 3 of each, the card said 3
    /// go-arounds and nothing else).
    func testTouchAndGoesAndGoAroundsShowTogether() {
        var flight = leg3()
        flight.touchAndGoCount = 3
        flight.goAroundCount = 3
        flight.fullStopCount = 0
        flight.fullStopTimes = []
        let counts = figures(flight).counts
        XCTAssertEqual(counts.touchAndGoes, 3)
        XCTAssertEqual(counts.goArounds, 3)
        XCTAssertEqual(counts.landings, 3, "the Logbook's landings: go-arounds are not landings")
    }

    /// A point `nm` nautical miles east of the reference, on the same parallel.
    private func point(eastNM nm: Double, of origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let metersPerDegree = 111_320 * cos(origin.latitude * .pi / 180)
        return CLLocationCoordinate2D(latitude: origin.latitude,
                                      longitude: origin.longitude + nm * 1852 / metersPerDegree)
    }

    /// A flight with one fix at each place and time, and its full stops at the given times.
    private func makeFlight(at stops: [(time: String, place: CLLocationCoordinate2D)],
                        fullStops: [String], takeoff: String) -> Flight {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.gpsTrack = stops.map {
            GPSPoint(latitude: $0.place.latitude, longitude: $0.place.longitude, altitude: 500, timestamp: date($0.time))
        }
        flight.lineUpTime = date(takeoff)
        flight.fullStopTimes = fullStops.map(date)
        flight.fullStopCount = fullStops.count
        flight.landingTime = flight.fullStopTimes.last
        return flight
    }

    private let home = CLLocationCoordinate2D(latitude: 47.44, longitude: 7.07)

    /// Circuits with stop-and-goes: every full stop before the last is at the home runway.
    func testFullStopsBackAtTheDepartureAreStopAndGoes() {
        let runwayEnd = point(eastNM: 0.4, of: home)
        let flight = makeFlight(at: [("2026-04-30T09:09:00Z", home),
                                 ("2026-04-30T09:20:00Z", runwayEnd),
                                 ("2026-04-30T09:31:00Z", home),
                                 ("2026-04-30T09:42:00Z", runwayEnd)],
                            fullStops: ["2026-04-30T09:20:00Z", "2026-04-30T09:31:00Z", "2026-04-30T09:42:00Z"],
                            takeoff: "2026-04-30T09:09:00Z")
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: flight).stopAndGoes, 2)
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: flight).stops, 0)
    }

    /// Home → LSGE, landed, took off again, back home: LSGE is a stop at another aerodrome, not a
    /// stop-and-go.
    func testAFullStopAtAnotherAerodromeIsAStop() {
        let away = point(eastNM: 38, of: home)
        let flight = makeFlight(at: [("2026-09-29T09:46:00Z", home),
                                 ("2026-09-29T10:20:00Z", away),
                                 ("2026-09-29T11:20:00Z", home)],
                            fullStops: ["2026-09-29T10:20:00Z", "2026-09-29T11:20:00Z"],
                            takeoff: "2026-09-29T09:46:00Z")
        let split = ShareCardFigures.intermediateFullStops(of: flight)
        XCTAssertEqual(split.stopAndGoes, 0)
        XCTAssertEqual(split.stops, 1)
        XCTAssertEqual(figures(flight).counts.stops, 1)
        XCTAssertEqual(figures(flight).counts.landings, 2)
    }

    /// Home → LSGE twice (a stop-and-go there) → LSGN: the first arrival at LSGE is a stop, the
    /// second is back at an aerodrome the flight already used.
    func testASecondFullStopAtTheSameAwayAerodromeIsAStopAndGo() {
        let lsge = point(eastNM: 38, of: home)
        let lsgn = point(eastNM: 60, of: home)
        let flight = makeFlight(at: [("2026-09-29T09:46:00Z", home),
                                 ("2026-09-29T10:20:00Z", lsge),
                                 ("2026-09-29T10:30:00Z", point(eastNM: 0.3, of: lsge)),
                                 ("2026-09-29T11:00:00Z", lsgn)],
                            fullStops: ["2026-09-29T10:20:00Z", "2026-09-29T10:30:00Z", "2026-09-29T11:00:00Z"],
                            takeoff: "2026-09-29T09:46:00Z")
        let split = ShareCardFigures.intermediateFullStops(of: flight)
        XCTAssertEqual(split.stops, 1)
        XCTAssertEqual(split.stopAndGoes, 1)
    }

    /// Stop-and-goes at the destination before the last landing there are circuits too.
    func testFullStopsAtTheFinalAerodromeAreStopAndGoes() {
        let destination = point(eastNM: 44, of: home)
        let flight = makeFlight(at: [("2026-03-20T13:57:00Z", home),
                                 ("2026-03-20T14:40:00Z", destination),
                                 ("2026-03-20T14:50:00Z", point(eastNM: 0.2, of: destination))],
                            fullStops: ["2026-03-20T14:40:00Z", "2026-03-20T14:50:00Z"],
                            takeoff: "2026-03-20T13:57:00Z")
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: flight).stopAndGoes, 1)
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: flight).stops, 0)
    }

    /// Only the track can say a full stop was elsewhere. Without it (no fix near the time, or times
    /// that do not match the count), every full stop before the last stays a stop-and-go (D1).
    func testAFullStopTheTrackCannotPlaceStaysAStopAndGo() {
        let away = point(eastNM: 38, of: home)
        var noFix = makeFlight(at: [("2026-09-29T09:46:00Z", home),
                                ("2026-09-29T11:20:00Z", home)],
                           fullStops: ["2026-09-29T10:20:00Z", "2026-09-29T11:20:00Z"],
                           takeoff: "2026-09-29T09:46:00Z")
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: noFix).stopAndGoes, 1)

        noFix.gpsTrack.append(GPSPoint(latitude: away.latitude, longitude: away.longitude, altitude: 500,
                                       timestamp: date("2026-09-29T10:20:00Z")))
        noFix.gpsTrack.sort { $0.timestamp < $1.timestamp }
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: noFix).stops, 1, "once placed, it is a stop")

        var legacy = noFix
        legacy.fullStopCount = 4       // more full stops than times
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: legacy).stopAndGoes, 3)
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: legacy).stops, 0)
    }

    func testOneFullStopIsTheLandingAndNothingElse() {
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: leg3()).stopAndGoes, 0)
        XCTAssertEqual(ShareCardFigures.intermediateFullStops(of: leg3()).stops, 0)
    }

    // MARK: - Credit line (B16)

    func testTheCreditNamesTheMapAndTheTerrainOnTheCard() {
        XCTAssertEqual(ShareCardFigures.credit(mapLayer: .icao, terrain: .swisstopo),
                       "Chart © swisstopo / BAZL · Terrain © swisstopo")
        XCTAssertEqual(ShareCardFigures.credit(mapLayer: .segelflugkarte, terrain: nil), "Chart © swisstopo / BAZL")
        XCTAssertEqual(ShareCardFigures.credit(mapLayer: .swissimage, terrain: .openMeteo),
                       "Imagery © swisstopo · Elevation: Open-Meteo")
        XCTAssertEqual(ShareCardFigures.credit(mapLayer: .standard, terrain: nil), "Map: Apple Maps")
        XCTAssertEqual(ShareCardFigures.credit(mapLayer: .satellite, terrain: nil), "Map: Apple Maps")
        XCTAssertEqual(ShareCardFigures.credit(mapLayer: nil, terrain: .openMeteo), "Elevation: Open-Meteo")
        XCTAssertNil(ShareCardFigures.credit(mapLayer: nil, terrain: nil))
    }

    /// The terrain credit names the service the profile actually came from.
    func testTheTerrainSourceIsSwisstopoOnlyForATrackStartingAndEndingInSwitzerland() {
        let bressaucourt = CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03)
        let ecuvillens = CLLocationCoordinate2D(latitude: 46.75, longitude: 7.08)
        let besancon = CLLocationCoordinate2D(latitude: 47.24, longitude: 5.83)
        XCTAssertEqual(ElevationService.trackTerrainSource(first: bressaucourt, last: ecuvillens), .swisstopo)
        XCTAssertEqual(ElevationService.trackTerrainSource(first: bressaucourt, last: besancon), .openMeteo)
        XCTAssertEqual(ElevationService.trackTerrainSource(first: besancon, last: besancon), .openMeteo)
    }

    // MARK: - Map style (B10)

    /// The track and the dots are sized in the map image's points and the image is rendered at a
    /// fixed scale, so they no longer grow with the screen (9 pt and 30 pt on a 3× iPhone).
    func testTheMapIsDrawnTheSameOnEveryDevice() {
        XCTAssertEqual(ShareCardMapStyle.renderScale, 2)
        XCTAssertEqual(ShareCardMapStyle.size, CGSize(width: 2032, height: 1500))
        XCTAssertEqual(ShareCardMapStyle.trackWidth / 2, 7, "7 pt on the card, on every layer")
        XCTAssertEqual(ShareCardMapStyle.markerDiameter / 2, 20)
    }

    // MARK: - French (B4)

    /// Every word on the card and in its sheet, as it is looked up, with its French. Half of them
    /// used to be plain strings that never reached the catalog.
    private static let frenchLabels: [String: String] = [
        "FLIGHT TIME": "TEMPS DE VOL",
        "BLOCK TIME": "TEMPS BLOC",
        "ENGINE TIME": "TEMPS MOTEUR",
        "SESSION TIME": "DURÉE DE SESSION",
        "MAX ALT": "ALT. MAX",
        "DISTANCE": "DISTANCE",
        "TAKE-OFF": "DÉCOLLAGE",
        "LANDING": "ATTERRISSAGE",
        "LANDINGS": "ATTERRISSAGES",
        "TOUCH-AND-GO": "POSÉ-DÉCOLLÉ",
        "TOUCH-AND-GOES": "POSÉS-DÉCOLLÉS",
        "GO-AROUND": "REMISE DE GAZ",
        "GO-AROUNDS": "REMISES DE GAZ",
        "STOP-AND-GO": "ARRÊT-DÉCOLLÉ",
        "STOP-AND-GOES": "ARRÊTS-DÉCOLLÉS",
        "STOP": "ESCALE",
        "STOPS": "ESCALES",
        "LT": "HL",
        "PEAK %@": "PIC %@",
        "ALTITUDE PROFILE": "PROFIL D'ALTITUDE",
        "ROUTE": "ROUTE",
        "Map unavailable (offline?)": "Carte indisponible (hors ligne ?)",
        "Chart © swisstopo / BAZL": "Carte © swisstopo / BAZL",
        "Imagery © swisstopo": "Imagerie © swisstopo",
        "Map: Apple Maps": "Carte : Plans d’Apple",
        "Terrain © swisstopo": "Relief © swisstopo",
        "Elevation: Open-Meteo": "Relief : Open-Meteo",
        "Share Card": "Carte de partage",
        "MAP STYLE": "STYLE DE CARTE",
        "COLOR THEME": "THÈME DE COULEUR",
        "TERRAIN": "RELIEF",
        "Share": "Partager",
        "Light": "Clair",
        "Aviation": "Aviation",
        "Navy": "Marine",
        "Dark": "Sombre",
        "Glider chart": "Carte vol à voile",
        "Share card": "Carte de partage",
        "Share stats card": "Partager une carte des statistiques",
    ]

    func testEveryShareCardLabelHasItsFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"), "the app ships French")
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        for (key, expected) in Self.frenchLabels {
            let value = french.localizedString(forKey: key, value: missing, table: nil)
            XCTAssertNotEqual(value, missing, "\(key) has no French")
            XCTAssertEqual(value, expected, key)
        }
    }

    /// The layer names are the nav map's own, which have their French already.
    func testTheLayerAndThemeNamesComeFromTheCatalog() {
        XCTAssertEqual(ShareCardMapLayer.icao.displayName, L10n.MapLayer.icao)
        XCTAssertEqual(ShareCardMapLayer.standard.displayName, L10n.MapLayer.standard)
        XCTAssertEqual(ShareCardMapLayer.satellite.displayName, L10n.MapLayer.satellite)
        XCTAssertEqual(ShareCardMapLayer.swissimage.displayName, L10n.MapLayer.swissimage)
        XCTAssertEqual(ShareCardMapLayer.segelflugkarte.displayName, L10n.ShareCard.gliderChart)
        XCTAssertEqual(ShareCardColorScheme.darkBlue.displayName, L10n.ShareCard.themeNavy)
        XCTAssertEqual(L10n.ShareCard.landings(1), "LANDING")
        XCTAssertEqual(L10n.ShareCard.landings(2), "LANDINGS")
        XCTAssertEqual(L10n.ShareCard.touchAndGoes(4), "TOUCH-AND-GOES")
        XCTAssertEqual(L10n.ShareCard.stops(1), "STOP")
    }
}
