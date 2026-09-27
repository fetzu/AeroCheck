import XCTest
@testable import AeroCheck

/// Locks the Wi-Fi Aware companion service contract.
///
/// The `WiFiAwareServices` Info.plist declaration and the name the code looks up
/// (`companionWiFiAwareServiceName`) must stay in exact sync, and the transport label MUST be
/// `._udp`. A `._tcp` name makes Apple's WiFiAware framework trap with an *uncatchable* assertion
/// while parsing the Info.plist — which crashed the app 100% of the time on flight start whenever
/// companion mode was enabled (the iPad master's `startListening()` forces that parse). These tests
/// guard that regression, since it can never be caught at runtime.
final class CompanionServiceContractTests: XCTestCase {

    func testServiceNameUsesUdpTransport() {
        XCTAssertTrue(
            companionWiFiAwareServiceName.hasSuffix("._udp"),
            "Wi-Fi Aware service name must use the ._udp transport label, not ._tcp — the framework traps on ._tcp")
    }

    func testInfoPlistDeclaresExactlyTheServiceTheCodeLooksUp() throws {
        let services = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "WiFiAwareServices") as? [String: Any],
            "Info.plist must declare a WiFiAwareServices dictionary")

        let entry = try XCTUnwrap(
            services[companionWiFiAwareServiceName] as? [String: Any],
            "WiFiAwareServices must declare '\(companionWiFiAwareServiceName)' — the exact name the code looks up via WAPublishableService/WASubscribableService.aerocheck")

        // The same universal binary publishes (iPad master) and subscribes (iPhone viewer), so the
        // single declared service must advertise both roles. Each role value MUST be a DICTIONARY
        // (empty is fine, per Apple's "Adopting Wi-Fi Aware") — a Bool makes WiFiAware trap with
        // "'Publishable' key ... is malformed (not a dictionary)", which crashed 100% on Pair New
        // Device on iOS/iPadOS 26. (v4.1 fix)
        XCTAssertNotNil(entry["Publishable"] as? [String: Any],
                        "companion service 'Publishable' must be a dictionary (iPad master) — a Bool crashes WiFiAware")
        XCTAssertNotNil(entry["Subscribable"] as? [String: Any],
                        "companion service 'Subscribable' must be a dictionary (iPhone viewer) — a Bool crashes WiFiAware")
    }

    func testNoStaleTcpServiceNameRemains() {
        let services = Bundle.main.object(forInfoDictionaryKey: "WiFiAwareServices") as? [String: Any] ?? [:]
        XCTAssertNil(
            services["_aerocheck._tcp"],
            "A ._tcp service name must never reappear in WiFiAwareServices — it traps the WiFiAware parser on flight start")
    }

    // MARK: - Automatic pairing role (v4.1 — pairing UX simplification)

    func testCompanionRoleIsAutomaticByDeviceType() {
        // Wi-Fi Aware pairing is asymmetric; the role is derived from device type, not a user setting,
        // so two devices can never accidentally take the same role and fail to discover each other.
        XCTAssertEqual(CompanionRole.automatic(for: .pad), .master, "iPad drives / advertises")
        XCTAssertEqual(CompanionRole.automatic(for: .phone), .viewer, "iPhone connects / browses")
    }

    // MARK: - Shared GPS: source election (v4.1)

    func testElectionPrefersOwnGPS() {
        let e = GPSSourceElection()
        XCTAssertEqual(e.elect(ownValid: true, peerValid: true), .own, "own wins even when the peer is also valid")
        XCTAssertEqual(e.elect(ownValid: true, peerValid: false), .own)
    }

    func testElectionFallsBackToPeerWhenOwnInvalid() {
        XCTAssertEqual(GPSSourceElection().elect(ownValid: false, peerValid: true), .peer)
    }

    func testElectionNoneWhenNeitherValid() {
        XCTAssertEqual(GPSSourceElection().elect(ownValid: false, peerValid: false), .none)
    }

    func testFixValidityBoundsAccuracyAndAge() {
        let e = GPSSourceElection(maxFixAge: 5, maxAccuracy: 100)
        XCTAssertTrue(e.isValid(accuracy: 20, age: 2))
        XCTAssertFalse(e.isValid(accuracy: 200, age: 1), "too inaccurate")
        XCTAssertFalse(e.isValid(accuracy: 20, age: 10), "too old (the freshness window doubles as hysteresis)")
        XCTAssertFalse(e.isValid(accuracy: -1, age: 1), "negative accuracy = invalid fix")
        XCTAssertFalse(e.isValid(accuracy: nil, age: 1), "no accuracy = invalid")
        XCTAssertFalse(e.isValid(accuracy: 20, age: nil), "no age = invalid")
        XCTAssertFalse(e.isValid(accuracy: .nan, age: 1), "NaN accuracy = invalid")
        XCTAssertFalse(e.isValid(accuracy: 20, age: .infinity), "non-finite age = invalid")
    }

    // MARK: - Shared GPS: peer-fix geometry (SA-10)
    //
    // A paired peer is a network trust boundary. Accuracy and age alone said nothing about the
    // COORDINATE, so a peer could pair a plausible 10 m accuracy with an out-of-range or non-finite
    // latitude/longitude and be elected — after which the raw values reach MKCoordinateRegion /
    // MKAnnotation, and MapKit raises on an invalid coordinate: a mid-flight crash of the navigation
    // display. The same point also lands in the recorded track, corrupting the flight file.

    private func peerFix(lat: Double, lon: Double, accuracy: Double = 10,
                         altitude: Double? = 500, speed: Double? = 30,
                         course: Double? = 90) -> CompanionPeerGPS {
        CompanionPeerGPS(latitude: lat, longitude: lon, speedMPS: speed, altitudeMeters: altitude,
                         courseDegrees: course, horizontalAccuracy: accuracy,
                         signalStatus: "good", timestamp: Date())
    }

    func testPeerFixGeometryAcceptsARealCoordinate() {
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0).hasValidGeometry)
        // Extremes of the valid range must still pass.
        XCTAssertTrue(peerFix(lat: 90, lon: 180).hasValidGeometry)
        XCTAssertTrue(peerFix(lat: -90, lon: -180).hasValidGeometry)
    }

    func testPeerFixGeometryRejectsNonFiniteCoordinates() {
        XCTAssertFalse(peerFix(lat: .nan, lon: 8.0).hasValidGeometry, "NaN latitude")
        XCTAssertFalse(peerFix(lat: 47.0, lon: .nan).hasValidGeometry, "NaN longitude")
        XCTAssertFalse(peerFix(lat: .infinity, lon: 8.0).hasValidGeometry, "+inf latitude")
        XCTAssertFalse(peerFix(lat: 47.0, lon: -.infinity).hasValidGeometry, "-inf longitude")
    }

    // SEC-C15: finiteness was not enough. A FINITE but absurd speed/altitude passed every gate and
    // reached `Int(displaySmoothedSpeedMPS * 1.94384)` in LocationManager — an uncatchable Swift
    // trap, i.e. a nearby paired device could kill the app in flight. Short of the trap, an
    // implausible value was simply displayed on the master's instruments and written to the track.
    func testPeerFixGeometryRejectsImplausibleSpeed() {
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, speed: 1e19).hasValidGeometry,
                       "finite but absurd speed traps Int(Double) downstream")
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, speed: 500).hasValidGeometry, "≈972 kt")
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, speed: -1).hasValidGeometry)
        // A realistic light-aircraft envelope must still pass.
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, speed: 60).hasValidGeometry, "≈117 kt")
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, speed: 0).hasValidGeometry, "stationary")
    }

    func testPeerFixGeometryRejectsImplausibleAltitude() {
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, altitude: 1e19).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, altitude: 50_000).hasValidGeometry, "50 km")
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, altitude: -2_000).hasValidGeometry)
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, altitude: 3_000).hasValidGeometry)
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, altitude: nil).hasValidGeometry, "absent is fine")
    }

    func testPeerFixGeometryRejectsImplausibleCourse() {
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, course: 720).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, course: -10).hasValidGeometry)
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, course: 359.9).hasValidGeometry)
    }

    func testPeerFixGeometryRejectsOutOfRangeCoordinates() {
        XCTAssertFalse(peerFix(lat: 4.0e9, lon: 8.0).hasValidGeometry, "the report's example value")
        XCTAssertFalse(peerFix(lat: 91, lon: 8.0).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: -90.001, lon: 8.0).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 181).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: -180.5).hasValidGeometry)
    }

    func testPeerFixGeometryRejectsNonFiniteMotionValues() {
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, altitude: .nan).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, speed: .infinity).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, course: .nan).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, accuracy: .nan).hasValidGeometry)
    }

    func testPeerFixGeometryAllowsAbsentMotionValues() {
        // Absent is fine — they degrade to CoreLocation's "unknown" sentinels.
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, altitude: nil, speed: nil, course: nil)
            .hasValidGeometry)
    }

    func testPeerFixElectionRequiresBothGeometryAndFreshness() {
        let e = GPSSourceElection(maxFixAge: 5, maxAccuracy: 100)

        XCTAssertTrue(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0), age: 1))
        // The attack: plausible accuracy, nonsense coordinate.
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 4.0e9, lon: 8.0, accuracy: 10), age: 1),
                       "a plausible accuracy must not launder an invalid coordinate")
        // The pre-existing gates still apply.
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0, accuracy: 200), age: 1))
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0), age: 10))
        XCTAssertFalse(e.isPeerFixValid(nil, age: 1), "no fix at all")
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0), age: nil))
    }

    func testPeerFixGeometryMatchesFlightIngestPredicate() {
        // The two validators must not drift apart: anything the companion path accepts must also
        // survive Flight.validatedForIngest(), or a borrowed fix corrupts the flight file and the
        // record silently fails to sync to the pilot's other devices.
        for (lat, lon) in [(47.0, 8.0), (90.0, 180.0), (-90.0, -180.0),
                           (Double.nan, 8.0), (4.0e9, 8.0), (47.0, 181.0)] {
            let fix = peerFix(lat: lat, lon: lon)
            let flight = Flight(
                gpsTrack: [GPSPoint(latitude: lat, longitude: lon, altitude: 500,
                                    speed: 30, course: 90)]
            )
            XCTAssertEqual(fix.hasValidGeometry, flight.validatedForIngest() != nil,
                           "companion and flight-ingest validators disagree on (\(lat), \(lon))")
        }
    }

    // MARK: - Shared GPS: wire codecs (v4.1)

    func testPeerGPSRoundTrips() throws {
        let gps = CompanionPeerGPS(latitude: 47.0, longitude: 8.0, speedMPS: 30, altitudeMeters: 1000,
                                   courseDegrees: 90, horizontalAccuracy: 5, signalStatus: "good",
                                   timestamp: Date(timeIntervalSince1970: 1000))
        let decoded = try JSONDecoder().decode(CompanionPeerGPS.self, from: JSONEncoder().encode(gps))
        XCTAssertEqual(decoded, gps)
    }

    func testPeerGPSTolerantDecodeDefaults() throws {
        // A skewed/partial payload still decodes (never drops the update); absent accuracy reads invalid.
        let decoded = try JSONDecoder().decode(CompanionPeerGPS.self, from: Data(#"{"latitude":47,"longitude":8}"#.utf8))
        XCTAssertEqual(decoded.horizontalAccuracy, -1, "absent accuracy -> invalid")
        XCTAssertNil(decoded.speedMPS)
    }

    func testFlightDataOwnGPSAvailableDefaultsTrueForLegacyPayload() throws {
        // A pre-shared-GPS master (no ownGPSAvailable field) is assumed to have its own fix.
        let decoded = try JSONDecoder().decode(CompanionFlightData.self, from: Data(#"{"isFlightActive":true}"#.utf8))
        XCTAssertTrue(decoded.ownGPSAvailable)
    }

    // MARK: - Viewer entitlement handshake (SA-26)
    //
    // The master streams the full challenge/response text of whatever checklist it is running.
    // Pairing is one system sheet plus one confirmation code, after which devices reconnect
    // automatically in proximity — so without a gate, someone with no subscription could pair to a
    // subscriber's iPad once and then read the whole premium checklist, and drive it.

    func testViewerHelloRoundTrips() throws {
        for entitled in [true, false] {
            let hello = CompanionViewerHello(isSubscribed: entitled)
            let decoded = try JSONDecoder().decode(
                CompanionViewerHello.self, from: JSONEncoder().encode(hello))
            XCTAssertEqual(decoded, hello)
        }
    }

    func testViewerHelloDefaultsToUnentitled() throws {
        // An older viewer that predates this message, or a malformed one, must read as NOT
        // entitled. Failing closed costs an old viewer some text; failing open defeats the check.
        let empty = try JSONDecoder().decode(CompanionViewerHello.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isSubscribed)

        let wrongKey = try JSONDecoder().decode(
            CompanionViewerHello.self, from: Data(#"{"subscribed":true}"#.utf8))
        XCTAssertFalse(wrongKey.isSubscribed, "an unrecognised key must not grant entitlement")
    }

    func testViewerHelloIsAViewerToMasterMessageType() {
        // Guards the wire vocabulary: the type must exist and round-trip, or the master silently
        // never learns the viewer's entitlement and (correctly, but unhelpfully) redacts forever.
        XCTAssertEqual(CompanionMessage.MessageType(rawValue: "viewerHello"), .viewerHello)
    }

    // MARK: - Deferred items on the viewer (v6.0 review, B2)

    func testChecklistSnapshotCarriesDeferredItems() throws {
        let snapshot = CompanionChecklistSnapshot(
            phaseTitle: "Taxi", phaseRawValue: 5, highlightedIndex: 2, visibleCount: 3, completedCount: 2,
            items: [], hiddenItemCount: 0, deferredItemIds: ["a"], deferredItemCount: 3)
        let decoded = try JSONDecoder().decode(CompanionChecklistSnapshot.self,
                                               from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.deferredItemIds, ["a"])
        XCTAssertEqual(decoded.deferredItemCount, 3)
    }

    func testChecklistSnapshotFromAnOlderMasterHasNothingDeferred() throws {
        // A 5.x or 6.0 iPad sends no deferred fields; the viewer must still take the update.
        let decoded = try JSONDecoder().decode(
            CompanionChecklistSnapshot.self,
            from: Data(#"{"phaseTitle":"Taxi","phaseRawValue":5,"highlightedIndex":1}"#.utf8))
        XCTAssertEqual(decoded.highlightedIndex, 1)
        XCTAssertEqual(decoded.deferredItemIds, [])
        XCTAssertEqual(decoded.deferredItemCount, 0)
    }

    /// SA-26 covers the deferred ids too: an item's id carries its challenge text. (v6.0 review, security)
    @MainActor
    func testAnUnentitledViewerGetsNoDeferredIds() throws {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        let item = try XCTUnwrap(appState.activeChecklist.visibleItems(for: appState.currentPhase, learningMode: true)
            .first { !$0.isHeader })
        appState.deferredItems[appState.currentPhase] = [item.id]
        XCTAssertEqual(appState.deferredItemCount, 1, "a real deferred item, so the redaction has something to hide")

        let redacted = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false)
        XCTAssertTrue(redacted.items.isEmpty)
        XCTAssertTrue(redacted.deferredItemIds.isEmpty, "the id would spell out the challenge")
        let wire = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
        XCTAssertFalse(wire.contains(item.challenge), "no challenge text anywhere in the snapshot")
        XCTAssertEqual(redacted.deferredItemCount, 1, "the count still goes")

        let full = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: true)
        XCTAssertEqual(full.deferredItemIds, [item.id])
    }

    /// Who gets the words: a Pro aircraft's from an iPad entitled to them, the bundled aircraft's
    /// always. The iPad's own entitlement decides, not what the viewer says about itself (S9-30).
    func testTheTextGateFollowsTheMastersOwnEntitlement() {
        XCTAssertFalse(CompanionConnectivityManager.mayStreamItemText(masterIsEntitled: false, remoteAircraftSelected: true))
        XCTAssertTrue(CompanionConnectivityManager.mayStreamItemText(masterIsEntitled: true, remoteAircraftSelected: true))
        XCTAssertTrue(CompanionConnectivityManager.mayStreamItemText(masterIsEntitled: false, remoteAircraftSelected: false))
    }

    /// A viewer claiming a subscription changes nothing on an iPad without one. (S9-30)
    @MainActor
    func testAViewersClaimDoesNotUnlockTheText() throws {
        let manager = CompanionConnectivityManager(defaults: makeTestDefaults(), usesWiFiAware: false)
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = "pa28-181"
        XCTAssertTrue(appState.settings.isRemoteAircraftSelected)
        let location = LocationManager()
        let plans = makeTestPlanManager()
        manager.configure(appState: appState, locationManager: location, flightPlanManager: plans)
        manager.currentRole = .master
        addTeardownBlock { @MainActor in manager.disconnect() }
        manager.entitlementProvider = { false }
        let gen = try XCTUnwrap(manager.adoptMasterConnection(identity: nil, send: { _ in }))

        let claim = CompanionMessage(type: .viewerHello,
                                     payload: try JSONEncoder().encode(CompanionViewerHello(isSubscribed: true)))
        manager.handleReceivedMessage(claim, generation: gen)
        XCTAssertFalse(manager.streamsItemText, "redacted: the claim is not proof")

        manager.entitlementProvider = { true }
        XCTAssertTrue(manager.streamsItemText, "an entitled iPad streams what it shows")

        appState.settings.selectedRemoteAircraftId = nil
        manager.entitlementProvider = { false }
        XCTAssertTrue(manager.streamsItemText, "the bundled aircraft always")
    }

    // MARK: - CHECK and DEFER from the viewer (v6.0 review, decision 2)

    func testTheNewCommandsRoundTrip() throws {
        for command in [CompanionCommand.deferChecklistItem,
                        .checkDeferredItem(phaseRawValue: 3, itemId: "2.I.Fuel"),
                        .checkInDeferredCheck(phaseRawValue: 4),
                        .deferInDeferredCheck(phaseRawValue: 4),
                        .toggleChecklistItem(phaseRawValue: 0, itemId: "1.I.Papers")] {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(CompanionCommand.self, from: data)
            XCTAssertEqual(String(describing: decoded), String(describing: command))
        }
    }

    /// An iPad built before these fields says nothing about DEFER: the viewer must not offer it.
    func testAnOlderMasterDoesNotOfferDefer() throws {
        let decoded = try JSONDecoder().decode(CompanionChecklistSnapshot.self,
                                               from: Data(#"{"phaseTitle":"Taxi","highlightedIndex":0}"#.utf8))
        XCTAssertFalse(decoded.supportsDefer)
        XCTAssertTrue(decoded.deferredGroups.isEmpty)
        XCTAssertEqual(decoded.openItemCount, 0)
    }

    @MainActor
    func testTheViewerGetsTheDeferredListOnlyWhenEntitled() throws {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        let phase = appState.currentPhase
        let items = appState.activeChecklist.visibleItems(for: phase, learningMode: true).filter { !$0.isHeader }
        let item = try XCTUnwrap(items.first)
        appState.deferredItems[phase] = [item.id]

        let full = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: true)
        XCTAssertTrue(full.supportsDefer)
        XCTAssertEqual(full.deferredGroups.first?.phaseRawValue, phase.rawValue)
        XCTAssertEqual(full.deferredGroups.first?.items.map(\.id), [item.id], "the master's own id, to check it by")
        XCTAssertEqual(full.openItemCount, appState.openItems(in: phase).count)

        let redacted = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false)
        XCTAssertTrue(redacted.supportsDefer, "DEFER needs no text")
        XCTAssertTrue(redacted.deferredGroups.isEmpty, "no challenge text for an unentitled viewer")
        XCTAssertEqual(redacted.openItemCount, full.openItemCount, "the count still goes")
    }

    /// A check deferred whole goes to every viewer as a title and counts; its items, to run it, only to
    /// a viewer entitled to them. (v6.0 review, J1)
    @MainActor
    func testDeferredChecksReachTheViewerWithTheSameGate() throws {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = true
        try XCTSkipIf(appState.checkItems(.preflight).isEmpty)
        appState.goToPhase(.beforeEngineStart)
        XCTAssertEqual(appState.deferredChecks, [.preflight])

        let full = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: true)
        let check = try XCTUnwrap(full.deferredChecks.first)
        XCTAssertEqual(check.phaseRawValue, ChecklistPhase.preflight.rawValue)
        XCTAssertEqual(check.items.map(\.id), appState.checkItems(.preflight).map(\.id))
        XCTAssertEqual(check.highlightedIndex, 0)
        XCTAssertEqual(check.remaining, check.total)

        let redacted = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false)
        let bare = try XCTUnwrap(redacted.deferredChecks.first)
        XCTAssertTrue(bare.items.isEmpty, "no challenge text for an unentitled viewer")
        XCTAssertTrue(bare.deferredItemIds.isEmpty)
        XCTAssertEqual(bare.total, check.total, "the counts still go")

        let decoded = try JSONDecoder().decode(CompanionChecklistSnapshot.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decoded.deferredChecks, full.deferredChecks)
    }

    /// The phone's commands do on the iPad what the iPad's own taps do: RUN and CHECK in a deferred
    /// check, and a tap on a checked row (by id, in the phase it was sent for). (v6.0 review, J1, K-C)
    @MainActor
    func testTheViewersCommandsActOnTheMastersChecklist() throws {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = true
        let plans = makeTestPlanManager()
        let items = appState.checkItems(.preflight)
        try XCTSkipIf(items.count < 3 || items[0].isHeader || items[1].isHeader)

        appState.goToPhase(.beforeEngineStart)
        CompanionConnectivityManager.apply(.checkInDeferredCheck(phaseRawValue: ChecklistPhase.preflight.rawValue),
                                           appState: appState, flightPlanManager: plans)
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 1)
        CompanionConnectivityManager.apply(.deferInDeferredCheck(phaseRawValue: ChecklistPhase.preflight.rawValue),
                                           appState: appState, flightPlanManager: plans)
        XCTAssertEqual(appState.deferredItems[.preflight], [items[1].id])

        let current = appState.checkItems(.beforeEngineStart)
        try XCTSkipIf(current.isEmpty || current[0].isHeader)
        appState.advanceHighlightedItem(learningMode: appState.effectiveLearningMode)
        let toggle = CompanionCommand.toggleChecklistItem(phaseRawValue: ChecklistPhase.beforeEngineStart.rawValue,
                                                          itemId: current[0].id)
        CompanionConnectivityManager.apply(toggle, appState: appState, flightPlanManager: plans)
        XCTAssertEqual(appState.deferredItems[.beforeEngineStart], [current[0].id], "reopened alone")
        CompanionConnectivityManager.apply(toggle, appState: appState, flightPlanManager: plans)
        XCTAssertNil(appState.deferredItems[.beforeEngineStart], "and checked again")

        // Sent for a phase the iPad has since left: nothing moves.
        let stale = CompanionCommand.toggleChecklistItem(phaseRawValue: ChecklistPhase.preflight.rawValue,
                                                         itemId: items[0].id)
        CompanionConnectivityManager.apply(stale, appState: appState, flightPlanManager: plans)
        XCTAssertEqual(appState.deferredItems[.preflight], [items[1].id])
    }
}
