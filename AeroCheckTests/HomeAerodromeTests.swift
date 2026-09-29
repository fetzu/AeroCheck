import XCTest
import CoreLocation
@testable import AeroCheck

/// The home aerodrome and the nav log's "Landings (base / total)" (v6.1).
///
/// Until 6.1 both counters came out wrong on the author's flights (LSZQ → LSGE → LSGN → LSZQ, one
/// full stop each): 0 / 0, because each landing was confirmed in the post-flight review, after END
/// FLIGHT had already settled the plan. Had they been confirmed in flight, the old rule would have
/// printed 1 / 1 on all three, because it counted every landing at base. These tests pin the new
/// rules: the total is the flight's confirmed landings, whenever they change; base is the landings at
/// the home aerodrome the pilot set, and unknown (never 0) without one.
@MainActor
final class HomeAerodromeTests: XCTestCase {

    // MARK: - Fixtures

    private static let fields: [String: CLLocationCoordinate2D] = [
        "LSZQ": .init(latitude: 47.3924, longitude: 7.0290),   // Bressaucourt
        "LSGE": .init(latitude: 46.7553, longitude: 7.0757),   // Ecuvillens
        "LSGN": .init(latitude: 46.9574, longitude: 6.8646),   // Neuchâtel
    ]

    /// The airport data's answer, stood in for: the nearest of `fields` within the app's 5 NM.
    private func aerodrome(at coordinate: CLLocationCoordinate2D) -> String? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Self.fields
            .map { ($0.key, here.distance(from: CLLocation(latitude: $0.value.latitude, longitude: $0.value.longitude))) }
            .filter { $0.1 <= HomeAerodrome.radiusNm * 1852 }
            .min { $0.1 < $1.1 }?.0
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A fix on the runway of `field`, `minutes` into the flight.
    private func fix(_ field: String, _ minutes: Double) -> GPSPoint {
        let at = Self.fields[field]!
        return GPSPoint(latitude: at.latitude + 0.002, longitude: at.longitude,
                        altitude: 450, timestamp: t0.addingTimeInterval(minutes * 60), speed: 25)
    }

    /// A flight with its landings at the given fields and minutes, and a fix at each; `fullStops` and
    /// `touchAndGos` are (field, minute).
    private func flight(from departure: String, fullStops: [(String, Double)],
                        touchAndGos: [(String, Double)] = [], planId: UUID? = nil) -> Flight {
        let landings = fullStops + touchAndGos
        var track = [fix(departure, 0)]
        track += landings.sorted { $0.1 < $1.1 }.map { fix($0.0, $0.1) }
        return Flight(flightPlanId: planId,
                      startTime: t0,
                      departureAirportIdent: departure,
                      gpsTrack: track,
                      touchAndGoCount: touchAndGos.count,
                      fullStopCount: fullStops.count,
                      touchAndGoTimes: touchAndGos.map { t0.addingTimeInterval($0.1 * 60) },
                      fullStopTimes: fullStops.map { t0.addingTimeInterval($0.1 * 60) })
    }

    private func plan(_ from: String, _ to: String) -> FlightPlan {
        FlightPlan(name: "\(from) → \(to)", waypoints: [
            FlightPlanWaypoint(name: from, coordinate: Self.fields[from]!),
            FlightPlanWaypoint(name: to, coordinate: Self.fields[to]!),
        ])
    }

    // MARK: - Counting

    /// Base vs away, touch-and-goes included: two touch-and-goes and the final full stop at home, a
    /// stop-and-go and a touch-and-go at Ecuvillens.
    func testTheCountAtBaseIsTheLandingsAtTheHomeAerodrome() {
        let flown = flight(from: "LSZQ",
                           fullStops: [("LSGE", 40), ("LSZQ", 90)],
                           touchAndGos: [("LSZQ", 8), ("LSZQ", 15), ("LSGE", 45)])
        let tally = LandingTally.of(flown, home: "LSZQ", aerodromeAt: aerodrome(at:))
        XCTAssertEqual(tally.total, 5, "touch-and-goes and full stops")
        XCTAssertEqual(tally.atHome, 3)

        let fromEcuvillens = LandingTally.of(flown, home: "lsge ", aerodromeAt: aerodrome(at:))
        XCTAssertEqual(fromEcuvillens.atHome, 2, "the ident as typed: trimmed, upper-cased")
    }

    /// The author's three flights, with LSZQ as home: 0 / 1, 0 / 1, 1 / 1. The old rule printed 1 / 1
    /// on each, a destination's landing counted at base.
    func testTheAuthorsDayReadsZeroZeroOne() {
        let legs = [("LSZQ", "LSGE"), ("LSGE", "LSGN"), ("LSGN", "LSZQ")]
        let atHome = legs.map { from, to in
            LandingTally.of(flight(from: from, fullStops: [(to, 35)]), home: "LSZQ", aerodromeAt: aerodrome(at:)).atHome
        }
        XCTAssertEqual(atHome, [0, 0, 1])
    }

    /// Without a home aerodrome the count at base is unknown, not 0: a 0 would say none was made there.
    /// The same when the airport data can't answer, when a landing has no fix near it, or when an import
    /// carried the counts without their times.
    func testTheCountAtBaseIsUnknownRatherThanGuessed() {
        let flown = flight(from: "LSZQ", fullStops: [("LSZQ", 30)])
        XCTAssertEqual(LandingTally.of(flown, home: nil, aerodromeAt: aerodrome(at:)),
                       LandingTally(total: 1, atHome: nil), "no home aerodrome set")
        XCTAssertNil(LandingTally.of(flown, home: "LSZQ", aerodromeAt: nil).atHome, "no airport data")
        XCTAssertNil(LandingTally.of(flown, home: "../..", aerodromeAt: aerodrome(at:)).atHome, "not an ident")

        var sparse = flown
        sparse.gpsTrack = [fix("LSZQ", 0)]   // nothing within two minutes of the landing
        XCTAssertNil(LandingTally.of(sparse, home: "LSZQ", aerodromeAt: aerodrome(at:)).atHome)

        var imported = flown
        imported.fullStopTimes = []
        XCTAssertEqual(LandingTally.of(imported, home: "LSZQ", aerodromeAt: aerodrome(at:)),
                       LandingTally(total: 1, atHome: nil))

        // A field landing, away from any aerodrome, is a landing away from home
        let outlanding = flight(from: "LSZQ", fullStops: [("LSZQ", 30)])
        XCTAssertEqual(LandingTally.of(outlanding, home: "LSZQ", aerodromeAt: { _ in nil }).atHome, 0)
    }

    // MARK: - END FLIGHT

    /// END FLIGHT fills both counters, in the plan list and in the copy attached to the flight. The same
    /// steps as `FlightView.performEndFlight`.
    func testSettlingFillsBothCounters() throws {
        for (home, expectedBase) in [("LSZQ", 0), ("LSGE", 1)] {
            let datastore = makeTestDatastore()
            let manager = makeTestPlanManager(datastore: datastore)
            let appState = makeTestAppState(datastore: datastore)
            let armed = plan("LSZQ", "LSGE")
            manager.add(armed)
            manager.activateFlightPlan(armed)
            addTeardownBlock { @MainActor in manager.stopChronometer() }

            appState.startFlight(withAircraft: appState.settings.defaultAirplane, flightPlanId: armed.id)
            let recorded = flight(from: "LSZQ", fullStops: [("LSGE", 35)])
            appState.currentFlight?.gpsTrack = recorded.gpsTrack
            appState.lineUpTime = t0.addingTimeInterval(60)
            appState.recordFullStop(at: recorded.fullStopTimes[0])

            let flying = try XCTUnwrap(appState.currentFlight)
            let landings = LandingTally.of(flying, home: home, aerodromeAt: aerodrome(at:))
            let flown = manager.settleFlownPlan(flying, takeoff: appState.lineUpTime, landing: appState.landingTime,
                                                landedAt: nil, landings: landings)
            appState.endFlight(withFlightPlan: flown)
            manager.deactivateFlightPlan()

            let listed = try XCTUnwrap(manager.flightPlans.first { $0.id == armed.id })
            XCTAssertEqual(listed.totalLandings, 1)
            XCTAssertEqual(listed.landingsAtBase, expectedBase, "home \(home)")
            let attached = try XCTUnwrap(appState.flights.first { $0.id == flying.id }?.flightPlan)
            XCTAssertEqual(attached.totalLandings, 1)
            XCTAssertEqual(attached.landingsAtBase, expectedBase)
        }
    }

    /// With no home aerodrome, END FLIGHT leaves the count at base empty and the nav log prints "–".
    func testSettlingWithoutAHomeAerodromeLeavesBaseEmpty() throws {
        let manager = makeTestPlanManager()
        let armed = plan("LSZQ", "LSGE")
        manager.add(armed)
        manager.activateFlightPlan(armed)
        addTeardownBlock { @MainActor in manager.stopChronometer() }

        let flown = flight(from: "LSZQ", fullStops: [("LSGE", 35)], planId: armed.id)
        let settled = try XCTUnwrap(manager.settleFlownPlan(flown, takeoff: t0, landing: flown.fullStopTimes[0],
                                                            landedAt: nil))
        XCTAssertEqual(settled.totalLandings, 1)
        XCTAssertNil(settled.landingsAtBase)
        XCTAssertEqual(settled.landingsText, "– / 1")
    }

    /// A number the pilot typed into the plan stays; the app only fills what is empty.
    func testSettlingKeepsWhatThePilotTyped() {
        var typed = plan("LSZQ", "LSGE")
        typed.totalLandings = 4
        typed.landingsAtBase = 3
        let settled = typed.settlingLandings(LandingTally(total: 1, atHome: 0))
        XCTAssertEqual(settled.totalLandings, 4)
        XCTAssertEqual(settled.landingsAtBase, 3)
    }

    // MARK: - The post-flight review

    /// The author's case: no landing confirmed in flight, so END FLIGHT settled 0 / 0; the review then
    /// found the full stop and the pilot took it. The plan follows now, in both copies. It didn't.
    func testALandingConfirmedInTheReviewResettlesThePlan() throws {
        let datastore = makeTestDatastore()
        let manager = makeTestPlanManager(datastore: datastore)
        let appState = makeTestAppState(datastore: datastore)
        let armed = plan("LSGN", "LSZQ")
        manager.add(armed)
        manager.activateFlightPlan(armed)
        addTeardownBlock { @MainActor in manager.stopChronometer() }

        appState.startFlight(withAircraft: appState.settings.defaultAirplane, flightPlanId: armed.id)
        let track = flight(from: "LSGN", fullStops: [("LSZQ", 35)]).gpsTrack
        appState.currentFlight?.gpsTrack = track
        let flying = try XCTUnwrap(appState.currentFlight)
        let count = { (flight: Flight) in LandingTally.of(flight, home: "LSZQ", aerodromeAt: self.aerodrome(at:)) }
        let flown = manager.settleFlownPlan(flying, takeoff: t0, landing: nil, landedAt: nil, landings: count(flying))
        appState.endFlight(withFlightPlan: flown)
        manager.deactivateFlightPlan()
        XCTAssertEqual(manager.flightPlans.first { $0.id == armed.id }?.totalLandings, 0, "END FLIGHT: no landing yet")

        let touchdown = t0.addingTimeInterval(35 * 60)
        let review = FlightReconciliation.Result(
            flightId: flying.id,
            events: [.init(type: .fullStop, timestamp: touchdown, airportIdent: "LSZQ", source: .detectedOnly)],
            trackBlockOff: nil, trackBlockOn: nil, backfillsBlockOff: false, backfillsBlockOn: false)
        let counted = try XCTUnwrap(appState.applyReconciliation(review, landings: count))
        let reviewed = try XCTUnwrap(appState.flights.first { $0.id == flying.id })
        manager.resettleLandings(of: reviewed, previous: counted.previous, updated: counted.updated)

        XCTAssertEqual(counted.updated, LandingTally(total: 1, atHome: 1))
        XCTAssertEqual(reviewed.flightPlan?.totalLandings, 1, "the copy attached to the flight")
        XCTAssertEqual(reviewed.flightPlan?.landingsAtBase, 1)
        let listed = try XCTUnwrap(manager.flightPlans.first { $0.id == armed.id })
        XCTAssertEqual(listed.totalLandings, 1, "the plan list's copy")
        XCTAssertEqual(listed.landingsAtBase, 1)
    }

    /// The review replaces what END FLIGHT wrote, never what the pilot typed since.
    func testTheReviewReplacesOnlyWhatTheAppWrote() {
        var settled = plan("LSZQ", "LSGE").settlingLandings(LandingTally(total: 2, atHome: 2))
        settled.landingsAtBase = 1   // corrected by hand
        let reviewed = settled.settlingLandings(LandingTally(total: 3, atHome: 2),
                                                replacing: LandingTally(total: 2, atHome: 2))
        XCTAssertEqual(reviewed.totalLandings, 3)
        XCTAssertEqual(reviewed.landingsAtBase, 1)
    }

    // MARK: - The Flight Log and the printed nav log

    /// Flights already logged: the Flight Log's nav log counts from the flight, whatever the stored copy
    /// says (0 / 0 from a review-confirmed landing, or the old base = total), and stores nothing.
    func testTheFlightLogCountsFromTheFlight() {
        var stored = plan("LSZQ", "LSGE")
        stored.totalLandings = 0
        stored.landingsAtBase = 0
        let flown = flight(from: "LSZQ", fullStops: [("LSGE", 35)])
        let shown = stored.showingLandings(LandingTally.of(flown, home: "LSZQ", aerodromeAt: aerodrome(at:)))
        XCTAssertEqual(shown.landingsText, "0 / 1")

        stored.totalLandings = 1
        stored.landingsAtBase = 1   // the rule before 6.1
        XCTAssertEqual(stored.showingLandings(LandingTally(total: 1, atHome: 0)).landingsText, "0 / 1")
    }

    /// Blank on a plan not flown yet, like the other after-flight boxes; "–" for a count that can't be
    /// known. The spreadsheet's column is named after the home aerodrome, as the club's form does.
    func testTheNavLogPrintsWhatIsKnown() throws {
        var navLog = plan("LSZQ", "LSGE")
        XCTAssertEqual(navLog.landingsText, "", "not flown yet: the pilot writes them in")
        navLog.totalLandings = 3
        XCTAssertEqual(navLog.landingsText, "– / 3")
        navLog.landingsAtBase = 2
        XCTAssertEqual(navLog.landingsText, "2 / 3")

        let withHome = try XCTUnwrap(FlightPlanExportService.exportToXLSX(navLog, homeIdent: "LSGN"))
        let sheet = try XCTUnwrap(String(data: withHome, encoding: .utf8))
        XCTAssertTrue(sheet.contains("LSGN / total"))
        XCTAssertTrue(sheet.contains(">2 / 3<"))
        let withoutHome = try XCTUnwrap(FlightPlanExportService.exportToXLSX(navLog))
        XCTAssertTrue(try XCTUnwrap(String(data: withoutHome, encoding: .utf8)).contains("Base / total"))
    }

    // MARK: - The setting

    /// A settings file from before 6.1 has no home aerodrome: it decodes to none, and the rest with it.
    func testAnOlderSettingsFileDecodesWithoutOne() throws {
        let older = #"{"pilotName":"J. Bono","gpsRecordingInterval":10,"schemaVersion":5}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(older.utf8))
        XCTAssertNil(settings.homeAerodromeIdent)
        XCTAssertEqual(settings.pilotName, "J. Bono", "the rest of the file with it")

        var set = settings
        set.homeAerodromeIdent = "LSZQ"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(decoded.homeAerodromeIdent, "LSZQ")

        let odd = #"{"homeAerodromeIdent":"../../Documents","schemaVersion":6}"#
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: Data(odd.utf8)).homeAerodromeIdent)
        let notAString = #"{"homeAerodromeIdent":42,"pilotName":"J. Bono","schemaVersion":6}"#
        let kept = try JSONDecoder().decode(AppSettings.self, from: Data(notAString.utf8))
        XCTAssertEqual(kept.pilotName, "J. Bono", "one bad value doesn't cost the whole file")
    }

    /// A device on an older build can't carry the home aerodrome: its sync record keeps this device's.
    /// A writer on this schema is taken at its word, a cleared one included.
    func testSyncKeepsItFromAnOlderWriter() {
        var local = AppSettings()
        local.homeAerodromeIdent = "LSZQ"

        var older = AppSettings()
        older.schemaVersion = 5
        older.homeAerodromeIdent = nil
        XCTAssertEqual(local.preservingFieldsUnknownTo(older).homeAerodromeIdent, "LSZQ")

        var current = AppSettings()
        current.homeAerodromeIdent = nil
        XCTAssertNil(local.preservingFieldsUnknownTo(current).homeAerodromeIdent, "cleared on purpose")

        var tampered = AppSettings()
        tampered.homeAerodromeIdent = "LSZQ/../x"
        XCTAssertNil(tampered.clampedForIngest().homeAerodromeIdent)
        XCTAssertEqual(AppSettings.currentSchemaVersion, 6)
    }

    // MARK: - The suggestion

    /// Where the flying days begin: the author's day (LSZQ → LSGE → LSGN → LSZQ) suggests LSZQ, where the
    /// most frequent departure alone would be a three-way tie. The most recent day breaks a tie.
    func testTheSuggestionIsWhereFlyingDaysBegin() {
        func flown(_ from: String, _ hoursAfter: Double) -> Flight {
            Flight(startTime: t0.addingTimeInterval(hoursAfter * 3600), departureAirportIdent: from)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = [flown("LSGN", 3), flown("LSZQ", 0), flown("LSGE", 1.2)]
        XCTAssertEqual(HomeAerodrome.suggestion(from: day, calendar: utc), "LSZQ")

        let tie = day + [flown("LSGE", 48)]   // a later day begins at LSGE
        XCTAssertEqual(HomeAerodrome.suggestion(from: tie, calendar: utc), "LSGE", "the most recent day")
        let settled = tie + [flown("LSZQ", 96)]
        XCTAssertEqual(HomeAerodrome.suggestion(from: settled, calendar: utc), "LSZQ")

        XCTAssertNil(HomeAerodrome.suggestion(from: [], calendar: utc))
        XCTAssertNil(HomeAerodrome.suggestion(from: [Flight(startTime: t0)], calendar: utc), "no departure known")
    }
}
