import XCTest
import CoreLocation
import MapKit
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

    /// The times say once, under them, which zone they are in: the offset on the flight's day.
    func testTimesSayWhetherTheyAreLocalOrUTC() {
        let flight = leg3()
        let local = figures(flight, useUTC: false)
        XCTAssertEqual(local.time(flight.lineUpTime!), "14:18")
        XCTAssertEqual(local.timeNote, "Local time · UTC+2", "CEST on 29 Sep")
        XCTAssertEqual(local.timeZoneLabel, L10n.ShareCard.localTimeLabel)

        var winter = leg3()
        winter.lineUpTime = date("2026-02-13T09:18:00Z")
        XCTAssertEqual(figures(winter).timeNote, "Local time · UTC+1", "CET in February")

        let utc = figures(flight, useUTC: true)
        XCTAssertEqual(utc.time(flight.lineUpTime!), "12:18")
        XCTAssertEqual(utc.timeNote, L10n.ShareCard.timesInUTC)
        XCTAssertEqual(utc.timeZoneLabel, "UTC")
    }

    func testTheOffsetIsWrittenAsPilotsWriteIt() {
        XCTAssertEqual(ShareCardFigures.utcOffset(7200), "UTC+2")
        XCTAssertEqual(ShareCardFigures.utcOffset(19_800), "UTC+5:30")
        XCTAssertEqual(ShareCardFigures.utcOffset(-10_800), "UTC-3")
        XCTAssertEqual(ShareCardFigures.utcOffset(0), "UTC")
    }

    /// Block off, take-off, landing, block on: the four times, in the card's zone.
    func testTheRowOfTimesHasTheFourLoggedTimes() {
        let cells = figures(leg3()).timeCells
        XCTAssertEqual(cells.map(\.kind), [.blockOff, .takeoff, .landing, .blockOn])
        XCTAssertEqual(cells.map(\.value), ["14:11", "14:18", "14:44", "14:45"])

        var noBlock = leg3()
        noBlock.blockOffTime = nil
        noBlock.blockOnTime = nil
        XCTAssertEqual(figures(noBlock).timeCells.map(\.kind), [.takeoff, .landing], "only the times the flight has")
        XCTAssertEqual(figures(leg3()).airborneSpan, "14:18–14:44")
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
    /// fixed scale, so they no longer grow with the screen (9 pt and 30 pt on a 3× iPhone). The
    /// image is twice its frame on the card, at the frame's exact shape, one pixel per pixel of the
    /// shared image.
    func testTheMapIsDrawnTheSameOnEveryDevice() {
        XCTAssertEqual(ShareCardMapStyle.renderScale, 1)
        XCTAssertEqual(ShareCardMapStyle.imagePointsPerCardPoint * ShareCardMapStyle.renderScale, 2,
                       "the card is shared at 2×: the map's pixels are the image's")
        XCTAssertEqual(ShareCardMapStyle.imageSize(for: CGSize(width: 1016, height: 750)),
                       CGSize(width: 2032, height: 1500))
        XCTAssertEqual(ShareCardMapStyle.standard.trackWidth / 2, 7, "7 pt on the card, on every layer")
        XCTAssertEqual(ShareCardMapStyle.standard.markerDiameter / 2, 20)
        XCTAssertEqual(ShareCardMapStyle.fullMap.trackWidth / 2, 8, "the bigger chart, the bigger track")
        XCTAssertEqual(ShareCardMapStyle.standard.waypointSide / 2, 11)
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
        "PEAK %@": "PIC %@",
        "ALTITUDE PROFILE": "PROFIL D'ALTITUDE",
        "MAX ALTITUDE": "ALTITUDE MAX",
        "MAX GROUND SPEED": "VITESSE SOL MAX",
        "BLOCK OFF": "BLOC OFF",
        "BLOCK ON": "BLOC ON",
        "Local time · %@": "Heure locale · %@",
        "Times in UTC": "Heures en UTC",
        "LOCAL TIME": "HEURE LOCALE",
        "National map © swisstopo": "Carte nationale © swisstopo",
        "STYLE": "STYLE",
        "Standard": "Standard",
        "Full map": "Pleine carte",
        "FORMAT": "FORMAT",
        "Story, 9:16": "Story, 9:16",
        "Feed post, 4:5": "Publication, 4:5",
        "Hide where I parked": "Masquer où j’ai stationné",
        "Leaves out the track's first and last 300 m": "Retire les 300 premiers et derniers mètres de la trace",
        "Short flight: drawn on the national map, sharper at this scale":
            "Vol court : affiché sur la carte nationale, plus nette à cette échelle",
        "Drawn on the glider chart, sharper at this scale": "Affiché sur la carte vol à voile, plus nette à cette échelle",
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

    // MARK: - The route as flown (B12)

    /// 29 Sep, leg 1 as recorded: the plan's six points, each with its time over.
    private func leg1() -> Flight {
        var flight = Flight(airplane: "wt9-dynamic", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        flight.departureAirportIdent = "LSZQ"
        flight.arrivalAirportIdent = "LSGE"
        flight.blockOffTime = date("2026-09-29T09:39:19Z")
        flight.lineUpTime = date("2026-09-29T09:46:20Z")
        flight.landingTime = date("2026-09-29T10:19:56Z")
        flight.blockOnTime = date("2026-09-29T10:21:40Z")
        flight.fullStopCount = 1
        flight.fullStopTimes = [flight.landingTime!]
        var plan = FlightPlan(name: "", waypoints: [
            waypoint("LSZQ", 47.392, 7.029, .aerodrome, "2026-09-29T09:46:20Z"),
            waypoint("E", 47.08, 6.95, .vrp, "2026-09-29T09:58:59Z", aerodrome: "LSGC"),
            waypoint("WITZWIL", 46.98, 7.07, .vrp, "2026-09-29T10:04:14Z"),
            waypoint("MURTEN", 46.93, 7.12, .vrp, "2026-09-29T10:07:40Z"),
            waypoint("GROLLEY", 46.84, 7.08, .vrp, "2026-09-29T10:11:29Z"),
            waypoint("LSGE", 46.755, 7.076, .aerodrome, "2026-09-29T10:19:56Z"),
        ])
        plan.aircraftRegistration = "F-HVXA"
        plan.aircraftModelName = "WT9 Dynamic"
        flight.flightPlan = plan
        return flight
    }

    private func waypoint(_ name: String, _ latitude: Double, _ longitude: Double, _ kind: WaypointPointKind?,
                          _ ato: String?, aerodrome: String? = nil) -> FlightPlanWaypoint {
        FlightPlanWaypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                           actualTimeOver: ato.map(date), pointKind: kind,
                           sourceId: kind == .aerodrome ? name : nil, aerodromeICAO: aerodrome)
    }

    private func names(_ stops: [ShareCardRouteStop]) -> [String] { stops.map(\.name) }

    /// Each waypoint in the long form, with its actual time over under it; the ends are the take-off
    /// and the landing.
    func testTheStripIsTheRouteFlownWithEachTimeOver() {
        let flight = leg1()
        let stops = ShareCardRoute.flown(flight, plan: flight.flightPlan)
        XCTAssertEqual(names(stops), ["LSZQ", "E (LSGC)", "WITZWIL", "MURTEN", "GROLLEY", "LSGE"])
        XCTAssertEqual(stops.map(\.shortName), ["LSZQ", "E", "WITZWIL", "MURTEN", "GROLLEY", "LSGE"])
        XCTAssertEqual(stops.map(\.role), [.departure, .waypoint, .waypoint, .waypoint, .waypoint, .arrival])
        let times = stops.map { $0.time.map(figures(flight).time) }
        XCTAssertEqual(times, ["11:46", "11:58", "12:04", "12:07", "12:11", "12:19"])
        XCTAssertEqual(RouteNameForm.shareCard, .full)
    }

    /// A plan made before 6.0.1 has "E" without its aerodrome: the sheet finds it in the reporting
    /// points on the device.
    func testAReportingPointWithoutItsAerodromeIsQualifiedFromTheData() {
        var plan = leg1().flightPlan!
        plan.waypoints[1].aerodromeICAO = nil
        plan.waypoints[1].sourceId = "629cc7abf4b4089a578e3c55"
        let qualified = ShareCardRoute.qualifyingReportingPoints(plan) { waypoint in
            waypoint.sourceId == "629cc7abf4b4089a578e3c55" ? "LSGC" : nil
        }
        XCTAssertEqual(qualified.waypoints[1].routeName(.full), "E (LSGC)")
        XCTAssertEqual(qualified.waypoints[2].aerodromeICAO, nil, "WITZWIL has none to find")
        XCTAssertEqual(qualified.waypoints[0], plan.waypoints[0], "nothing else changes")
    }

    /// A waypoint the aircraft never came abeam of was not flown: it is not on the strip. The map
    /// still shows the plan's waypoints, all of them.
    func testAWaypointNotFlownIsLeftOut() {
        var flight = leg1()
        flight.flightPlan!.waypoints[3].actualTimeOver = nil      // MURTEN, a corner cut
        let stops = ShareCardRoute.flown(flight, plan: flight.flightPlan)
        XCTAssertEqual(names(stops), ["LSZQ", "E (LSGC)", "WITZWIL", "GROLLEY", "LSGE"])
        XCTAssertEqual(ShareCardRoute.mapWaypoints(flight.flightPlan).map(\.label),
                       ["E", "WITZWIL", "MURTEN", "GROLLEY"])
    }

    /// Diverted to LSGC: the strip ends where the flight landed, not at the planned LSGE, and the
    /// rest of the route (never passed) is not on it.
    func testADiversionEndsAtTheFieldLandedAt() {
        var flight = leg1()
        flight.arrivalAirportIdent = "LSGC"
        for index in 2...5 { flight.flightPlan!.waypoints[index].actualTimeOver = nil }
        flight.flightPlan!.diversion = Diversion(ident: "LSGC", name: "Les Eplatures", latitude: 47.08, longitude: 6.79,
                                                 startedAt: date("2026-09-29T10:00:00Z"), leftRouteAt: 2)
        let stops = ShareCardRoute.flown(flight, plan: flight.flightPlan)
        XCTAssertEqual(names(stops), ["LSZQ", "E (LSGC)", "LSGC"])
        XCTAssertEqual(stops.last?.time, flight.landingTime)
    }

    /// Landed somewhere the plan did not go, with no diversion recorded: the aerodrome landed at,
    /// as the title says; "?" when it is not known.
    func testALandingElsewhereEndsAtThatAerodrome() {
        var flight = leg1()
        flight.arrivalAirportIdent = "LSGN"
        flight.flightPlan!.waypoints[5].actualTimeOver = nil
        XCTAssertEqual(names(ShareCardRoute.flown(flight, plan: flight.flightPlan)).last, "LSGN")

        flight.arrivalAirportIdent = nil
        XCTAssertEqual(names(ShareCardRoute.flown(flight, plan: flight.flightPlan)).last, Flight.unknownAerodrome)
    }

    /// A plan whose ends are named in words ("Bressaucourt", 23 Sep) keeps the flight's idents, as
    /// the title does.
    func testTheEndsAreTheFlightsAerodromes() {
        var flight = leg1()
        flight.flightPlan!.waypoints[0] = waypoint("Bressaucourt", 47.392, 7.029, nil, "2026-09-29T09:46:20Z")
        flight.flightPlan!.waypoints[5] = waypoint("Ecuvillens", 46.755, 7.076, nil, "2026-09-29T10:19:56Z")
        let stops = ShareCardRoute.flown(flight, plan: flight.flightPlan)
        XCTAssertEqual(stops.first?.name, "LSZQ")
        XCTAssertEqual(stops.last?.name, "LSGE")
    }

    /// A point with no name used to vanish from the strip: it keeps its place as its number.
    func testAnUnnamedPointIsShownAsItsNumber() {
        var flight = leg1()
        flight.flightPlan!.waypoints[2].name = ""
        flight.flightPlan!.waypoints[2].pointKind = .user
        let stops = ShareCardRoute.flown(flight, plan: flight.flightPlan)
        XCTAssertEqual(names(stops), ["LSZQ", "E (LSGC)", "WPT 3", "MURTEN", "GROLLEY", "LSGE"])
        XCTAssertEqual(ShareCardRoute.mapWaypoints(flight.flightPlan)[1].label, "WPT 3")
    }

    /// Without a plan the strip is the two aerodromes; circuits and a round flight have none (the
    /// title says it).
    func testWithoutAPlanTheStripIsTheTwoAerodromes() {
        var flight = leg1()
        flight.flightPlan = nil
        let stops = ShareCardRoute.flown(flight, plan: nil)
        XCTAssertEqual(names(stops), ["LSZQ", "LSGE"])
        XCTAssertEqual(stops.map { $0.time.map(figures(flight).time) }, ["11:46", "12:19"])

        flight.arrivalAirportIdent = "LSZQ"
        XCTAssertEqual(ShareCardRoute.flown(flight, plan: nil), [])
        flight.arrivalAirportIdent = nil
        XCTAssertEqual(ShareCardRoute.flown(flight, plan: nil), [])
    }

    /// With no times over recorded (5.1), the card fills them from the track, as the Flight Log.
    func testTimesOverComeFromTheTrackWhenNoneWereRecorded() {
        var flight = leg1()
        for index in flight.flightPlan!.waypoints.indices { flight.flightPlan!.waypoints[index].actualTimeOver = nil }
        let start = flight.lineUpTime!
        flight.gpsTrack = (0...200).map { step in
            let fraction = Double(step) / 200
            let from = flight.flightPlan!.waypoints[0].coordinate, to = flight.flightPlan!.waypoints[5].coordinate
            return GPSPoint(latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                            longitude: from.longitude + (to.longitude - from.longitude) * fraction,
                            altitude: 1500, timestamp: start.addingTimeInterval(fraction * 2016), speed: 50)
        }
        let stops = FlightShareCard.route(for: flight)
        XCTAssertEqual(stops.first?.name, "LSZQ")
        XCTAssertEqual(stops.last?.name, "LSGE")
        XCTAssertTrue(stops.dropFirst().dropLast().allSatisfy { $0.time != nil }, "every point between has a time")
    }

    // MARK: - The strip's collapse rule

    /// B612 Mono is monospaced: 0.65 em a character, 12.35 pt at 19 pt.
    private func monoWidth(_ stop: ShareCardRouteStop) -> CGFloat { CGFloat(max(stop.name.count, 5)) * 12.35 }

    private func stops(_ names: [String]) -> [ShareCardRouteStop] {
        names.enumerated().map { index, name in
            ShareCardRouteStop(name: name, shortName: name, time: nil,
                               role: index == 0 ? .departure : (index == names.count - 1 ? .arrival : .waypoint))
        }
    }

    private func assertNoOverlap(_ placed: [ShareCardRouteStrip.Placed], width: CGFloat,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(placed, placed.dropFirst()) {
            XCTAssertLessThanOrEqual(a.labelX + a.labelWidth, b.labelX + 0.001, file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(placed.first?.labelX ?? -1, 0, file: file, line: line)
        XCTAssertLessThanOrEqual((placed.last?.labelX ?? 0) + (placed.last?.labelWidth ?? 0), width + 0.001,
                                 file: file, line: line)
    }

    /// Leg 1's six points fit the story's 984 pt: all of them, evenly spaced, no "···" (the old
    /// strip folded anything over seven points, fitting or not).
    func testEveryPointIsShownWhileTheNamesFit() {
        let route = stops(["LSZQ", "E (LSGC)", "WITZWIL", "MURTEN", "GROLLEY", "LSGE"])
        let placed = ShareCardRouteStrip.layout(route, width: 984, labelWidth: monoWidth)
        XCTAssertEqual(placed.map(\.item), route.map { .stop($0) })
        for (dot, expected) in zip(placed.map(\.dotX), [0, 196.8, 393.6, 590.4, 787.2, 984]) {
            XCTAssertEqual(dot, CGFloat(expected), accuracy: 0.001, "evenly spaced")
        }
        assertNoOverlap(placed, width: 984)

        // Nine short points fit too, where the old rule folded them.
        let nine = stops(["LSZQ", "E", "N", "W", "S", "NE", "SE", "V", "LSGE"])
        XCTAssertFalse(ShareCardRouteStrip.layout(nine, width: 984, labelWidth: monoWidth)
            .contains { if case .more = $0.item { return true } else { return false } })
    }

    /// When even steps would make two names touch, the labels are packed with equal gaps instead,
    /// still all shown.
    func testLongNamesArePackedBeforeAnythingIsFolded() {
        let route = stops(["LSZQ", "SAIGNELEGIER", "E (LSGC)", "CHASSERAL", "LSGE"])
        let placed = ShareCardRouteStrip.layout(route, width: 700, labelWidth: monoWidth)
        XCTAssertEqual(placed.count, 5)
        XCTAssertFalse(placed.contains { if case .more = $0.item { return true } else { return false } })
        assertNoOverlap(placed, width: 700)
    }

    /// 23 Sep's 26 points cannot fit: the middle ones fold into one "···" with how many, keeping
    /// as many as fit from both ends, and one more would not.
    func testTheMiddleFoldsOnlyPastWhatFits() {
        let names = ["LSZQ", "DEKAM", "BENOT", "ABNOR", "GUDAX", "ETIXO", "PINAM", "Brienz", "Meiringen", "Meiringen",
                     "WPT 11", "Grimsel", "Furka", "Oberalp", "Disentis", "Trun", "Ilanz", "Bonaduz", "Chur",
                     "Lenzerheide", "Savognin", "DIBIV", "Julier", "Silvaplana", "W", "LSZS"]
        let route = stops(names)
        let placed = ShareCardRouteStrip.layout(route, width: 984, labelWidth: monoWidth)
        assertNoOverlap(placed, width: 984)
        guard let more = placed.firstIndex(where: { if case .more = $0.item { return true } else { return false } }),
              case .more(let hidden) = placed[more].item else { return XCTFail("the middle folds") }
        let shown = placed.count - 1
        XCTAssertEqual(shown + hidden, names.count, "every point is either shown or counted")
        XCTAssertEqual(placed.first?.item, .stop(route[0]))
        XCTAssertEqual(placed.last?.item, .stop(route[25]))
        XCTAssertGreaterThan(shown, 5)

        // One more point kept would not fit.
        let head = more, tail = shown - head
        let widths = Array(route.prefix(head + 1)).map(monoWidth) + [ShareCardRouteStrip.moreWidth]
            + Array(route.suffix(tail)).map(monoWidth)
        let needed = widths.reduce(0, +) + CGFloat(widths.count - 1) * ShareCardRouteStrip.minimumGap
        XCTAssertGreaterThan(needed, 984)
    }

    // MARK: - The map: zoom 11, and the national map for short flights (B9, Q6)

    /// Leg 1's map is 1.73° wide in 2032 px: the ICAO chart at zoom 11, its highest, downsampled.
    func testTheICAOChartIsDrawnAtItsSharpestZoom() {
        let choice = ShareCardMapZoom.choice(for: .icao, lonSpan: 1.728, outputWidth: 2032)
        XCTAssertEqual(choice?.source, .icaoChart)
        XCTAssertEqual(choice?.zoom, 11)
        XCTAssertLessThan(ShareCardMapZoom.enlargement(lonSpan: 1.728, outputWidth: 2032, zoom: 11), 1)
        XCTAssertEqual(ShareCardMapZoom.choice(for: .segelflugkarte, lonSpan: 0.8, outputWidth: 2032)?.zoom, 12)
        XCTAssertEqual(ShareCardMapZoom.choice(for: .icao, lonSpan: 6, outputWidth: 2032)?.zoom, 9,
                       "a long flight: the zoom whose tiles are no more than 1.5 × the width")
    }

    /// A circuit is 0.115° wide: the ICAO chart would be enlarged about 10×, the glider chart 5×.
    /// It is drawn on the national map, sharp at that scale, and the credit names it.
    func testACircuitIsDrawnOnTheNationalMap() {
        let choice = ShareCardMapZoom.choice(for: .icao, lonSpan: 0.115, outputWidth: 2032)
        XCTAssertEqual(choice?.source, .nationalMap)
        XCTAssertEqual(choice?.zoom, 15)
        XCTAssertLessThanOrEqual(ShareCardMapZoom.enlargement(lonSpan: 0.115, outputWidth: 2032, zoom: 15), 2)
        XCTAssertEqual(ShareCardMapZoom.choice(for: .segelflugkarte, lonSpan: 0.115, outputWidth: 2032)?.source,
                       .nationalMap)
        XCTAssertEqual(ShareCardFigures.credit(map: choice?.source.credit, terrain: .swisstopo),
                       "National map © swisstopo · Terrain © swisstopo")
    }

    /// The switch happens past 2×, not before, and to the glider chart first: a short cross-country
    /// stays on an aviation chart (29 Sep leg 2 needs the ICAO chart at 2.3×, the glider chart at
    /// 1.15×); only past 2× on both does the national map come in.
    func testTheChartGivesWayOnlyPastTwiceItsSize() {
        let tile: Double = 360 / pow(2.0, 11.0)     // one z11 tile, in degrees
        // 2032 px over 4 tiles of z11 (1024 px) = 1.98×: kept.
        XCTAssertEqual(ShareCardMapZoom.choice(for: .icao, lonSpan: 4 * tile, outputWidth: 2032)?.source, .icaoChart)
        // 3.9 tiles = 2.03×: the glider chart at z12, 1.02×.
        let glider = ShareCardMapZoom.choice(for: .icao, lonSpan: 3.9 * tile, outputWidth: 2032)
        XCTAssertEqual(glider?.source, .gliderChart)
        XCTAssertEqual(glider?.zoom, 12)
        // 1.9 tiles: 4.2× on the ICAO chart, 2.1× on the glider chart: the national map.
        XCTAssertEqual(ShareCardMapZoom.choice(for: .icao, lonSpan: 1.9 * tile, outputWidth: 2032)?.source, .nationalMap)
        // Picked the glider chart: past 2× it goes straight to the national map.
        XCTAssertEqual(ShareCardMapZoom.choice(for: .segelflugkarte, lonSpan: 1.9 * tile, outputWidth: 2032)?.source,
                       .nationalMap)
        XCTAssertEqual(ShareCardTileSource.gliderChart.credit, .chart, "still a BAZL chart")
    }

    /// Imagery and Apple's maps are sharp at any scale of a flight: never switched.
    func testImageryAndAppleMapsAreNeverSwitched() {
        XCTAssertEqual(ShareCardMapZoom.choice(for: .swissimage, lonSpan: 0.115, outputWidth: 2032)?.source, .swissimage)
        XCTAssertNil(ShareCardMapZoom.choice(for: .standard, lonSpan: 0.115, outputWidth: 2032))
        XCTAssertNil(ShareCardMapZoom.choice(for: .satellite, lonSpan: 0.115, outputWidth: 2032))
        XCTAssertEqual(ShareCardMapLayer.standard.credit, .appleMaps)
        XCTAssertEqual(ShareCardMapLayer.icao.tileSource?.maxZoom, 11, "the layer serves 11 (B9)")
    }

    /// The Full map band keeps the track out of its fades: the track's box sits inside the part of
    /// the image that is not faded.
    func testTheTrackStaysClearOfTheFullMapFades() throws {
        let track = [CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03),
                     CLLocationCoordinate2D(latitude: 46.75, longitude: 7.08)]
        let rect = try XCTUnwrap(ShareCardMapFraming.rect(for: track, aspect: 1080.0 / 1210, clearTop: 0.1, clearBottom: 0.1))
        let box = MKPolyline(coordinates: track, count: 2).boundingMapRect
        XCTAssertEqual(rect.size.width / rect.size.height, 1080.0 / 1210, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(box.minY, rect.minY + 0.1 * rect.size.height)
        XCTAssertLessThanOrEqual(box.maxY, rect.maxY - 0.1 * rect.size.height)
        XCTAssertTrue(rect.contains(box))
    }

    // MARK: - Hide where I parked (Q7)

    private func straightTrack(meters: Double, step: Double = 25) -> [GPSPoint] {
        let origin = home
        let metersPerDegree = 111_320 * cos(origin.latitude * .pi / 180)
        return stride(from: 0.0, through: meters, by: step).enumerated().map { index, distance in
            GPSPoint(latitude: origin.latitude, longitude: origin.longitude + distance / metersPerDegree,
                     altitude: 450, timestamp: date("2026-09-29T09:39:00Z").addingTimeInterval(Double(index) * 6))
        }
    }

    private func meters(_ a: GPSPoint, _ b: GPSPoint) -> Double {
        Flight.haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Off by default; on, the track starts and ends 300 m from where the aircraft stood.
    func testHidingWhereIParkedCutsBothEndsBy300Metres() {
        let track = straightTrack(meters: 5000, step: 40)
        let trimmed = ShareCardPrivacy.trimmingParking(track)
        XCTAssertEqual(ShareCardPrivacy.parkingTrimMeters, 300)
        XCTAssertEqual(meters(trimmed.first!, track.first!), 300, accuracy: 1)
        XCTAssertEqual(meters(trimmed.last!, track.last!), 300, accuracy: 1)
        XCTAssertEqual(trimmed.count, track.count - 16 + 2, "the fixes within 300 m go, the two cuts come in")
    }

    /// The cut is by distance from the stand, not along the track: a long winding taxi near the
    /// hangar does not bring the green dot back next to it.
    func testTheCutIsMeasuredFromWhereTheAircraftStood() {
        var track: [GPSPoint] = []
        let base = date("2026-09-29T09:30:00Z")
        let metersPerDegree = 111_320 * cos(home.latitude * .pi / 180)
        // 600 m of taxi going back and forth within 150 m of the stand.
        for index in 0..<24 {
            let east = Double(index % 7) * 25
            track.append(GPSPoint(latitude: home.latitude, longitude: home.longitude + east / metersPerDegree,
                                  altitude: 450, timestamp: base.addingTimeInterval(Double(index) * 6)))
        }
        let away = straightTrack(meters: 4000, step: 40).map {
            GPSPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 450,
                     timestamp: base.addingTimeInterval(200 + $0.timestamp.timeIntervalSince(date("2026-09-29T09:39:00Z"))))
        }
        track += away
        let trimmed = ShareCardPrivacy.trimmingParking(track)
        XCTAssertGreaterThanOrEqual(meters(trimmed.first!, track.first!), 299)
        XCTAssertTrue(trimmed.allSatisfy { meters($0, track.first!) >= 299 || meters($0, track.last!) >= 299 })
    }

    /// A track that never went 300 m from where it started is all "where I parked": nothing is shown.
    func testATrackThatNeverLeftTheStandIsHiddenWhole() {
        XCTAssertEqual(ShareCardPrivacy.trimmingParking(straightTrack(meters: 250)).count, 0)
        XCTAssertEqual(ShareCardPrivacy.trimmingParking([]).count, 0)
    }

    // MARK: - Formats and layout (Q7)

    func testTheFormatsAreStoriesAndFeedPosts() {
        XCTAssertEqual(ShareCardFormat.story.size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ShareCardFormat.feed.size, CGSize(width: 1080, height: 1350))
        XCTAssertEqual(ShareCardFormat.feed.size.width / ShareCardFormat.feed.size.height, 4.0 / 5)
        XCTAssertEqual(ShareCardFormat.allCases.map(\.ratioLabel), ["9:16", "4:5"])
    }

    /// Every block has its height and the map takes the rest, so nothing is left empty above the
    /// footer (the old card left 293–388 pt): the blocks and the map add up to the card.
    func testTheMapTakesWhatIsLeftSoTheCardHasNoEmptyBand() {
        let story = ShareCardLayout(style: .standard, format: .story, hasRouteStrip: true, hasCounts: false)
        let blocks = story.topPadding + story.topBarHeight + story.titleGap + story.titleBlockHeight
            + story.routeGap + story.routeHeight + story.mapGap + story.tilesGap + story.tileHeight
            + story.profileGap + story.profileHeaderHeight + story.profileHeaderGap + story.profileHeight
            + story.timesGap + story.timesHeight + story.noteGap + story.noteHeight
            + story.footerGap + story.footerHeight + story.bottomPadding
        XCTAssertEqual(blocks + story.mapFrame.height, 1920, accuracy: 0.5)
        XCTAssertEqual(story.mapFrame.width, 1016)
        XCTAssertGreaterThan(story.mapFrame.height, 750, "taller than the mockup's, which left a band")

        let noStrip = ShareCardLayout(style: .standard, format: .story, hasRouteStrip: false, hasCounts: false)
        XCTAssertGreaterThan(noStrip.mapFrame.height, story.mapFrame.height)
        let counts = ShareCardLayout(style: .standard, format: .story, hasRouteStrip: true, hasCounts: true)
        XCTAssertEqual(counts.mapFrame.height, story.mapFrame.height - counts.countsGap - counts.countsHeight)

        let feed = ShareCardLayout(style: .standard, format: .feed, hasRouteStrip: true, hasCounts: false)
        XCTAssertGreaterThan(feed.mapFrame.height, 500, "a 4:5 post still leads with the map")
        XCTAssertFalse(feed.hasProfileHeader)
    }

    /// Full map: the chart edge to edge, most of the card, clear of the title and of the panel.
    func testTheFullMapBandRunsEdgeToEdge() {
        for format in ShareCardFormat.allCases {
            let layout = ShareCardLayout(style: .fullMap, format: format, hasRouteStrip: true, hasCounts: true)
            XCTAssertEqual(layout.mapFrame.width, 1080)
            XCTAssertGreaterThan(layout.mapFrame.height, format.size.height * 0.55, "\(format)")
            XCTAssertGreaterThan(layout.bandTop, layout.topPadding + layout.topBarHeight + layout.titleGap + layout.titleBlockHeight)
            XCTAssertLessThan(layout.bandBottom, format.size.height - layout.panelMargin - layout.panelHeight)
            XCTAssertGreaterThan(layout.mapClearTop, 0)
            XCTAssertEqual(layout.mapStyle, .fullMap)
        }
    }

    // MARK: - The tuned card's figures

    func testBlockTimeAndMaxGroundSpeed() {
        var flight = leg1()
        flight.gpsTrack = [GPSPoint(latitude: 47, longitude: 7, altitude: 500, speed: -1),
                           GPSPoint(latitude: 47, longitude: 7, altitude: 500, speed: 58.1),
                           GPSPoint(latitude: 47, longitude: 7, altitude: 500, speed: .nan)]
        XCTAssertEqual(figures(flight).blockTime, "0:42", "09:39 → 10:21, the minute rule")
        XCTAssertEqual(figures(flight).maxGroundSpeedKnots, 113)
        XCTAssertEqual(figures(flight).maxGroundSpeed, "113 kt")
        flight.gpsTrack = [GPSPoint(latitude: 47, longitude: 7, altitude: 500, speed: -1)]
        XCTAssertNil(figures(flight).maxGroundSpeed, "no fix knew its speed")
    }

    /// Under the title, the aerodromes' names in the title's order.
    func testTheAerodromesNamesGoUnderTheTitle() {
        let names = ["LSZQ": "Bressaucourt Airfield", "LSGE": "Ecuvillens Airfield", "LSGN": "NEUCHATEL"]
        let line = { (flight: Flight) in ShareCardFigures.aerodromeLine(for: flight) { names[$0] } }
        XCTAssertEqual(line(leg1()), "Bressaucourt → Ecuvillens")

        var circuits = leg1()
        circuits.arrivalAirportIdent = "LSZQ"
        circuits.touchAndGoCount = 4
        XCTAssertEqual(line(circuits), "Bressaucourt · \(L10n.Flights.circuits.localizedLowercase)")
        circuits.touchAndGoCount = 0
        XCTAssertEqual(line(circuits), "Bressaucourt", "a round flight")

        var unknown = leg1()
        unknown.arrivalAirportIdent = "LSXX"
        XCTAssertEqual(line(unknown), "Bressaucourt → LSXX", "an aerodrome without a name keeps its ident")
        unknown.departureAirportIdent = "LSYY"
        XCTAssertNil(line(unknown), "no name at all: the title says it already")

        XCTAssertEqual(ShareCardFigures.shortAerodromeName("NEUCHATEL"), "Neuchatel")
        XCTAssertEqual(ShareCardFigures.shortAerodromeName("Zurich Airport"), "Zurich")
        XCTAssertEqual(ShareCardFigures.shortAerodromeName("Airport"), "Airport")
    }

    /// Circuits get their row of counts; a flight with one landing does not (its times say it).
    func testTheCountsRowIsForCircuitsAndStops() {
        XCTAssertFalse(figures(leg1()).showsCounts)
        var circuits = leg1()
        circuits.touchAndGoCount = 4
        XCTAssertTrue(figures(circuits).showsCounts)
    }

    /// The model beside the registration: the plan's, when the plan was for this aircraft.
    func testTheBadgeNamesTheModelWhenThePlanWasForThisAircraft() {
        XCTAssertEqual(figures(leg1()).aircraftModel, "WT9 Dynamic")
        var other = leg1()
        other.flightPlan!.aircraftRegistration = "HB-PFA"
        XCTAssertEqual(figures(other).aircraftModel, "WT9", "another aircraft's plan: the flight's own type")
    }
}
