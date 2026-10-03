import XCTest
import CoreLocation
@testable import AeroCheck

/// What a paired peer may do to the master's flight, and when the pilot is asked (SEC-C40).
///
/// Being paired is not authorisation: the first request of a connection to act on the flight (a
/// command that changes something, or a position to borrow) asks the pilot, once. Allow holds for
/// this flight and that phone, reconnections included; Always Allow for that phone on this iPad until
/// it is forgotten or set back to Ask Each Flight; Don't Allow for the connection (6.1.0). A
/// keep-alive never asks (S9-08), a position needs the same answer as a command and a forgotten
/// device is refused (S9-09), and trust belongs to one connection, whose frames stop counting once
/// another replaced it (S9-28).
///
/// The manager here is a test one: its own defaults suite, and no Wi-Fi Aware, so nothing starts a
/// real listener on the simulator. Connections are adopted through the same entry point the
/// listener uses, with a send handler that goes nowhere.
@MainActor
final class CompanionPeerAuthorizationTests: XCTestCase {

    private struct Master {
        let manager: CompanionConnectivityManager
        let appState: AppState
        let location: LocationManager
        /// Held here: the manager keeps its data sources weakly.
        let plans: FlightPlanManager
        let defaults: UserDefaults
    }

    private func makeMaster(defaults: UserDefaults? = nil) -> Master {
        let defaults = defaults ?? makeTestDefaults()
        let manager = CompanionConnectivityManager(defaults: defaults, usesWiFiAware: false)
        let appState = makeTestAppState()
        let location = LocationManager()
        let plans = makeTestPlanManager()
        manager.configure(appState: appState, locationManager: location, flightPlanManager: plans)
        manager.currentRole = .master
        addTeardownBlock { @MainActor in manager.disconnect() }
        return Master(manager: manager, appState: appState, location: location, plans: plans, defaults: defaults)
    }

    private func connect(_ manager: CompanionConnectivityManager, id: UInt64? = 7,
                         name: String? = "Pilot's iPhone") throws -> Int {
        let identity = id.map { CompanionPeerIdentity(deviceID: $0, name: name) }
        return try XCTUnwrap(manager.adoptMasterConnection(identity: identity, send: { _ in }),
                             "the connection should have been adopted")
    }

    private func command(_ command: CompanionCommand) -> CompanionMessage {
        CompanionMessage(type: .command, payload: try! JSONEncoder().encode(command))
    }

    private func peerFix() -> CompanionMessage {
        let fix = CompanionPeerGPS(latitude: 46.9, longitude: 7.4, speedMPS: 50, altitudeMeters: 1_500,
                                   courseDegrees: 90, horizontalAccuracy: 5, signalStatus: "good",
                                   timestamp: Date())
        return CompanionMessage(type: .peerGPS, payload: try! JSONEncoder().encode(fix))
    }

    // MARK: - S9-08: the keep-alive never asks

    func testAKeepAliveNeverAsks() throws {
        let master = makeMaster()
        let gen = try connect(master.manager)

        // The viewer pings on connect and every 2 s after, whether or not it ever taps anything.
        for _ in 0..<20 {
            XCTAssertTrue(master.manager.handleReceivedMessage(command(.ping), generation: gen))
        }
        XCTAssertNil(master.manager.pendingAuthorization, "a ping must not raise the prompt")
        XCTAssertEqual(master.manager.peerLink?.hasAsked, false)
        XCTAssertEqual(master.manager.peerLink?.authorization, .undecided)
    }

    func testTheViewerHelloNeverAsks() throws {
        let master = makeMaster()
        let gen = try connect(master.manager)
        let hello = CompanionMessage(type: .viewerHello,
                                     payload: try JSONEncoder().encode(CompanionViewerHello(isSubscribed: true)))
        for _ in 0..<5 { master.manager.handleReceivedMessage(hello, generation: gen) }
        XCTAssertNil(master.manager.pendingAuthorization)
    }

    // MARK: - SEC-C40: asked once per connection, the answer remembered

    func testAnActionAsksOnceAndIsDroppedUntilAnswered() throws {
        let master = makeMaster()
        let gen = try connect(master.manager, name: "Student iPhone")

        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        let request = try XCTUnwrap(master.manager.pendingAuthorization, "the first action asks")
        XCTAssertEqual(request.generation, gen)
        XCTAssertEqual(request.deviceName, "Student iPhone", "the peer that asked, named by its own connection")
        XCTAssertFalse(master.appState.hiddenItemsRevealed, "not applied before the pilot answers")

        // More taps while the prompt is up: dropped, and the same question stays on screen.
        for _ in 0..<5 {
            master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
            master.manager.handleReceivedMessage(command(.ping), generation: gen)
        }
        XCTAssertEqual(master.manager.pendingAuthorization, request)
        XCTAssertFalse(master.appState.hiddenItemsRevealed)
    }

    func testDontAllowIsRememberedForTheConnection() throws {
        let master = makeMaster()
        let gen = try connect(master.manager)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        let request = try XCTUnwrap(master.manager.pendingAuthorization)

        master.manager.answerAuthorization(request, .deny)
        XCTAssertNil(master.manager.pendingAuthorization)
        XCTAssertEqual(master.manager.peerLink?.authorization, .denied)

        // Cancel used to clear the prompt only, and the next ping raised it again 2 s later.
        for _ in 0..<10 {
            master.manager.handleReceivedMessage(command(.ping), generation: gen)
            master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
            master.manager.handleReceivedMessage(peerFix(), generation: gen)
        }
        XCTAssertNil(master.manager.pendingAuthorization, "Don't Allow holds: no second prompt")
        XCTAssertFalse(master.appState.hiddenItemsRevealed)
        XCTAssertNil(master.manager.receivedPeerGPS)
    }

    func testAllowLetsTheConnectionAct() throws {
        let master = makeMaster()
        let gen = try connect(master.manager)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        master.manager.answerAuthorization(try XCTUnwrap(master.manager.pendingAuthorization), .allow)
        XCTAssertTrue(master.manager.peerMayIssueCommands)

        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        XCTAssertTrue(master.appState.hiddenItemsRevealed, "an allowed peer drives the checklist")
        XCTAssertNil(master.manager.pendingAuthorization)
    }

    func testAPromptLostWithoutAnAnswerMayAskAgain() throws {
        // SwiftUI can drop an alert it cannot present; the connection must not stay silently
        // ignored for good.
        let master = makeMaster()
        let gen = try connect(master.manager)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        master.manager.authorizationPromptDismissed(try XCTUnwrap(master.manager.pendingAuthorization))
        XCTAssertNil(master.manager.pendingAuthorization)

        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        XCTAssertNotNil(master.manager.pendingAuthorization)
    }

    func testAnotherPhoneDoesNotRideOnTheAllow() throws {
        let master = makeMaster()
        let first = try connect(master.manager, id: 7)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: first)
        master.manager.answerAuthorization(try XCTUnwrap(master.manager.pendingAuthorization), .allow)

        let second = try connect(master.manager, id: 8, name: "Club iPhone")
        XCTAssertFalse(master.manager.peerMayIssueCommands, "another phone's connection starts from nothing")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: second)
        XCTAssertEqual(master.manager.pendingAuthorization?.generation, second, "and is asked about")
        XCTAssertFalse(master.appState.hiddenItemsRevealed)
    }

    // MARK: - S9-28: trust bound to the connection

    func testAnAnswerForAReplacedConnectionAuthorisesNothing() throws {
        let master = makeMaster()
        let first = try connect(master.manager, id: 7, name: "Pilot's iPhone")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: first)
        let staleRequest = try XCTUnwrap(master.manager.pendingAuthorization)

        // Another paired phone takes over while the prompt is still up; the pilot then taps Allow.
        let second = try connect(master.manager, id: 8, name: "Someone else's iPhone")
        XCTAssertNil(master.manager.pendingAuthorization, "the old question went with its connection")
        master.manager.answerAuthorization(staleRequest, .allow)

        XCTAssertFalse(master.manager.peerMayIssueCommands, "the Allow was for the replaced connection")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: second)
        XCTAssertFalse(master.appState.hiddenItemsRevealed)
        XCTAssertEqual(master.manager.pendingAuthorization?.deviceName, "Someone else's iPhone")
    }

    func testFramesFromAReplacedConnectionAreDropped() throws {
        let master = makeMaster()
        let first = try connect(master.manager)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: first)
        master.manager.answerAuthorization(try XCTUnwrap(master.manager.pendingAuthorization), .allow)
        let second = try connect(master.manager, id: 8)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: second)
        master.manager.answerAuthorization(try XCTUnwrap(master.manager.pendingAuthorization), .allow)
        master.appState.hiddenItemsRevealed = false

        // The old connection's receive loop is still running: its frames count for nothing.
        XCTAssertFalse(master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: first),
                       "false tells the loop to stop reading that connection")
        XCTAssertFalse(master.appState.hiddenItemsRevealed, "no riding on the current peer's Allow")
        XCTAssertFalse(master.manager.handleReceivedMessage(peerFix(), generation: first))
        XCTAssertNil(master.manager.receivedPeerGPS)
        XCTAssertFalse(master.manager.handleReceivedMessage(CompanionMessage(type: .disconnect, payload: Data()),
                                                            generation: first))
        XCTAssertEqual(master.manager.connectionState, .connected, "a stray disconnect no longer kicks the viewer")
        XCTAssertEqual(master.manager.peerLink?.generation, second)
    }

    func testThePromptNamesThePeerThatAskedNotTheFirstPairedDevice() throws {
        let master = makeMaster()
        master.manager.pairedDevices = [
            CompanionPairedDevice(name: "Pilot's iPhone", pairingName: nil, deviceIDs: [7]),
            CompanionPairedDevice(name: "Club iPhone", pairingName: nil, deviceIDs: [8]),
        ]
        let gen = try connect(master.manager, id: 8, name: "Club iPhone")
        master.manager.handleReceivedMessage(command(.advanceWaypoint), generation: gen)
        XCTAssertEqual(master.manager.pendingAuthorization?.deviceName, "Club iPhone")
        XCTAssertEqual(master.manager.connectedDeviceName, "Club iPhone")
    }

    func testAnUnnamedPeerIsAskedAboutAsAPairedDevice() throws {
        let master = makeMaster()
        master.manager.pairedDevices = [CompanionPairedDevice(name: "Pilot's iPhone", pairingName: nil, deviceIDs: [7])]
        let gen = try connect(master.manager, id: nil)
        master.manager.handleReceivedMessage(command(.advanceWaypoint), generation: gen)
        let request = try XCTUnwrap(master.manager.pendingAuthorization)
        XCTAssertNil(request.deviceName, "no guess from the paired list")
        XCTAssertFalse(L10n.Companion.allowControlMessage(nil, canRemember: request.canRemember)
            .contains("Pilot's iPhone"))
    }

    // MARK: - S9-09: position needs the same answer

    func testPositionIsRefusedBeforeAuthorisation() throws {
        let master = makeMaster()
        let gen = try connect(master.manager)

        master.manager.handleReceivedMessage(peerFix(), generation: gen)
        XCTAssertNil(master.manager.receivedPeerGPS, "not stored")
        XCTAssertFalse(master.manager.hasUsablePeerFix, "cannot start a flight off it either")
        XCTAssertNil(master.location.currentLocation, "never reaches the flight pipeline")
        XCTAssertNotNil(master.manager.pendingAuthorization, "the pilot is asked, as for a command")

        master.manager.answerAuthorization(try XCTUnwrap(master.manager.pendingAuthorization), .allow)
        master.manager.handleReceivedMessage(peerFix(), generation: gen)
        XCTAssertNotNil(master.manager.receivedPeerGPS)
        XCTAssertEqual(master.manager.effectiveGPSSource, .peer)
        XCTAssertEqual(master.location.currentLocation?.coordinate.latitude ?? 0, 46.9, accuracy: 1e-9,
                       "an allowed peer's fix is borrowed, as before")
    }

    func testAnInvalidFixDoesNotAsk() throws {
        let master = makeMaster()
        let gen = try connect(master.manager)
        let nonsense = CompanionPeerGPS(latitude: 4.0e9, longitude: 7.4, speedMPS: nil, altitudeMeters: nil,
                                        courseDegrees: nil, horizontalAccuracy: 5, signalStatus: "good",
                                        timestamp: Date())
        master.manager.handleReceivedMessage(CompanionMessage(type: .peerGPS, payload: try JSONEncoder().encode(nonsense)),
                                             generation: gen)
        XCTAssertNil(master.manager.pendingAuthorization, "garbage is dropped, not put to the pilot")
    }

    // MARK: - S9-09: Forget

    func testAForgottenDeviceIsRefused() throws {
        let master = makeMaster()
        let oldPhone = CompanionPairedDevice(name: "Former member's iPhone", pairingName: nil, deviceIDs: [42, 43])
        master.manager.pairedDevices = [oldPhone]
        master.manager.forget(oldPhone)
        XCTAssertTrue(master.manager.isForgotten(oldPhone))
        XCTAssertFalse(master.manager.hasPairedDevices, "nothing left to connect to")

        for id: UInt64 in [42, 43] {
            XCTAssertNil(master.manager.adoptMasterConnection(identity: CompanionPeerIdentity(deviceID: id, name: nil),
                                                              send: { _ in }),
                         "every record behind the row is refused")
        }
        XCTAssertNotEqual(master.manager.connectionState, .connected)
        XCTAssertNil(master.manager.peerLink)

        // Another device still connects.
        XCTAssertNotNil(master.manager.adoptMasterConnection(identity: CompanionPeerIdentity(deviceID: 7, name: nil),
                                                             send: { _ in }))
    }

    func testForgettingIsKeptAndCanBeUndone() throws {
        let defaults = makeTestDefaults()
        let master = makeMaster(defaults: defaults)
        let phone = CompanionPairedDevice(name: "iPhone", pairingName: nil, deviceIDs: [UInt64.max])
        master.manager.forget(phone)

        // A relaunch: same defaults, new manager. UInt64.max does not fit an Int64, hence the strings.
        let relaunched = CompanionConnectivityManager(defaults: defaults, usesWiFiAware: false)
        XCTAssertTrue(relaunched.isForgotten(phone))

        relaunched.allowAgain(phone)
        XCTAssertFalse(relaunched.isForgotten(phone))
        XCTAssertFalse(CompanionConnectivityManager(defaults: defaults, usesWiFiAware: false).isForgotten(phone))
    }

    func testForgettingTheConnectedDeviceEndsTheLink() throws {
        let master = makeMaster()
        _ = try connect(master.manager, id: 7)
        master.manager.forget(CompanionPairedDevice(name: "Pilot's iPhone", pairingName: nil, deviceIDs: [7]))
        XCTAssertNotEqual(master.manager.connectionState, .connected)
        XCTAssertNil(master.manager.peerLink)
    }

    func testForgettingAnotherDeviceLeavesTheLinkUp() throws {
        let master = makeMaster()
        _ = try connect(master.manager, id: 7)
        master.manager.forget(CompanionPairedDevice(name: "Old iPhone", pairingName: nil, deviceIDs: [9]))
        XCTAssertEqual(master.manager.connectionState, .connected)
        XCTAssertEqual(master.manager.peerLink?.identity?.deviceID, 7)
    }

    func testTheRefusalRule() {
        let named = CompanionPeerIdentity(deviceID: 7, name: "iPhone")
        XCTAssertFalse(CompanionConnectivityManager.refusesPeer(named, forgotten: []))
        XCTAssertFalse(CompanionConnectivityManager.refusesPeer(nil, forgotten: []),
                       "with nothing forgotten an unnamed peer connects (and still has to be allowed)")
        XCTAssertTrue(CompanionConnectivityManager.refusesPeer(named, forgotten: [7]))
        XCTAssertFalse(CompanionConnectivityManager.refusesPeer(named, forgotten: [9]))
        XCTAssertTrue(CompanionConnectivityManager.refusesPeer(nil, forgotten: [9]),
                      "once something is forgotten, a peer Wi-Fi Aware will not name could be it")
    }

    // MARK: - 6.1.0: Allow for this flight

    private func startFlight(_ master: Master) {
        master.appState.settings.selectedAircraft = .wt9Dynamic   // bundled: nothing to resolve first
        master.appState.startFlight()
        XCTAssertTrue(master.appState.isFlightActive)
        addTeardownBlock { @MainActor in if master.appState.isFlightActive { master.appState.cancelFlight() } }
    }

    /// Ask on the connection `gen`, and answer.
    private func answer(_ master: Master, generation gen: Int, _ answer: CompanionAuthorizationAnswer) throws {
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        master.manager.answerAuthorization(try XCTUnwrap(master.manager.pendingAuthorization), answer)
        master.appState.hiddenItemsRevealed = false
    }

    /// Let the flight watch run: it hears of a start or an end on the main actor's next turns.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testAllowHoldsWhenThePhoneReconnectsDuringTheFlight() throws {
        let master = makeMaster()
        startFlight(master)
        try answer(master, generation: try connect(master.manager), .allow)

        // A Wi-Fi Aware drop, then the same phone back: not asked again.
        let again = try connect(master.manager)
        XCTAssertTrue(master.manager.peerMayIssueCommands, "the same phone, the same flight")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: again)
        XCTAssertTrue(master.appState.hiddenItemsRevealed)
        XCTAssertNil(master.manager.pendingAuthorization)
    }

    func testAllowEndsWithTheFlight() throws {
        let master = makeMaster()
        startFlight(master)
        try answer(master, generation: try connect(master.manager), .allow)
        master.appState.cancelFlight()

        let next = try connect(master.manager)
        XCTAssertFalse(master.manager.peerMayIssueCommands, "the flight it was given for is over")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: next)
        XCTAssertNotNil(master.manager.pendingAuthorization, "asked again")

        startFlight(master)
        _ = try connect(master.manager)
        XCTAssertFalse(master.manager.peerMayIssueCommands, "nor does it come back with the next flight")
    }

    func testAllowGivenBeforeTheFlightHoldsForTheNextOne() throws {
        let master = makeMaster()
        try answer(master, generation: try connect(master.manager), .allow)

        startFlight(master)
        _ = try connect(master.manager)
        XCTAssertTrue(master.manager.peerMayIssueCommands, "the flight it was given before")

        master.appState.cancelFlight()
        _ = try connect(master.manager)
        XCTAssertFalse(master.manager.peerMayIssueCommands, "and it ends with that one")
    }

    func testAPhoneStillConnectedIsAskedAgainAfterTheFlight() async throws {
        let master = makeMaster()
        startFlight(master)
        let gen = try connect(master.manager)
        try answer(master, generation: gen, .allow)

        master.appState.cancelFlight()
        await settle()
        XCTAssertFalse(master.manager.peerMayIssueCommands, "the connection outlived the flight, not the Allow")
        XCTAssertEqual(master.manager.peerLink?.generation, gen, "the link itself stays up")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        XCTAssertNotNil(master.manager.pendingAuthorization)
        XCTAssertFalse(master.appState.hiddenItemsRevealed)
    }

    func testAFlightFlownWhileThePhoneWasAwayEndsAnAllowGivenBeforeIt() async throws {
        let master = makeMaster()
        try answer(master, generation: try connect(master.manager), .allow)
        master.manager.disconnect()
        master.manager.currentRole = .master

        // A whole flight without the phone.
        startFlight(master)
        await settle()
        master.appState.cancelFlight()
        await settle()

        _ = try connect(master.manager)
        XCTAssertFalse(master.manager.peerMayIssueCommands, "the Allow went with the flight it was given for")
    }

    func testDontAllowStillHoldsForTheConnectionOnly() throws {
        let master = makeMaster()
        startFlight(master)
        try answer(master, generation: try connect(master.manager), .deny)

        let again = try connect(master.manager)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: again)
        XCTAssertNotNil(master.manager.pendingAuthorization, "a new connection is asked, as before")
    }

    // MARK: - 6.1.0: Always Allow

    func testAlwaysAllowIsKeptOnThisIPadAcrossFlightsAndRelaunches() throws {
        let defaults = makeTestDefaults()
        let master = makeMaster(defaults: defaults)
        let phone = CompanionPairedDevice(name: "Pilot's iPhone", pairingName: nil, deviceIDs: [UInt64.max])
        try answer(master, generation: try connect(master.manager, id: UInt64.max), .alwaysAllow)
        XCTAssertTrue(master.manager.isAlwaysAllowed(phone))

        startFlight(master)
        master.appState.cancelFlight()
        _ = try connect(master.manager, id: UInt64.max)
        XCTAssertTrue(master.manager.peerMayIssueCommands, "not bound to a flight")

        // A relaunch: same defaults, new manager. UInt64.max does not fit an Int64, hence the strings.
        let relaunched = makeMaster(defaults: defaults)
        XCTAssertTrue(relaunched.manager.isAlwaysAllowed(phone))
        let gen = try connect(relaunched.manager, id: UInt64.max)
        XCTAssertTrue(relaunched.manager.peerMayIssueCommands)
        relaunched.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        XCTAssertTrue(relaunched.appState.hiddenItemsRevealed)
        XCTAssertNil(relaunched.manager.pendingAuthorization, "never asked")
    }

    func testAlwaysAllowIsForThatPhoneOnly() throws {
        let master = makeMaster()
        try answer(master, generation: try connect(master.manager, id: 7), .alwaysAllow)

        let other = try connect(master.manager, id: 8, name: "Club iPhone")
        XCTAssertFalse(master.manager.peerMayIssueCommands)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: other)
        XCTAssertEqual(master.manager.pendingAuthorization?.deviceName, "Club iPhone")
    }

    func testAskEachFlightTakesAlwaysAllowBack() throws {
        let defaults = makeTestDefaults()
        let master = makeMaster(defaults: defaults)
        let phone = CompanionPairedDevice(name: "Pilot's iPhone", pairingName: nil, deviceIDs: [7])
        let gen = try connect(master.manager, id: 7)
        try answer(master, generation: gen, .alwaysAllow)

        master.manager.stopAlwaysAllowing(phone)
        XCTAssertFalse(master.manager.isAlwaysAllowed(phone))
        XCTAssertFalse(master.manager.peerMayIssueCommands, "from its next action on, this connection included")
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        XCTAssertNotNil(master.manager.pendingAuthorization, "asked again")
        XCTAssertFalse(master.appState.hiddenItemsRevealed)
        XCTAssertFalse(makeMaster(defaults: defaults).manager.isAlwaysAllowed(phone), "and that is stored")
    }

    func testForgetEndsEveryAllowance() throws {
        let defaults = makeTestDefaults()
        let master = makeMaster(defaults: defaults)
        let always = CompanionPairedDevice(name: "Pilot's iPhone", pairingName: nil, deviceIDs: [7])
        let forTheFlight = CompanionPairedDevice(name: "Student iPhone", pairingName: nil, deviceIDs: [9])
        startFlight(master)
        try answer(master, generation: try connect(master.manager, id: 7), .alwaysAllow)
        try answer(master, generation: try connect(master.manager, id: 8), .alwaysAllow)
        try answer(master, generation: try connect(master.manager, id: 9), .allow)

        for device in [always, forTheFlight] {
            master.manager.forget(device)
            master.manager.allowAgain(device)
            master.manager.currentRole = .master
            let gen = try connect(master.manager, id: device.deviceIDs[0])
            XCTAssertFalse(master.manager.peerMayIssueCommands, "allowed again, it starts from nothing")
            master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
            XCTAssertNotNil(master.manager.pendingAuthorization)
        }
        XCTAssertFalse(makeMaster(defaults: defaults).manager.isAlwaysAllowed(always), "and that is stored")
        XCTAssertTrue(master.manager.alwaysAllowedDevices.contains(8), "another phone keeps its own")
    }

    func testAPeerNotIdentifiedIsNeverRemembered() throws {
        let master = makeMaster()
        startFlight(master)
        let gen = try connect(master.manager, id: nil)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        let request = try XCTUnwrap(master.manager.pendingAuthorization)
        XCTAssertFalse(request.canRemember, "the prompt offers no Always")
        XCTAssertNotEqual(L10n.Companion.allowControlMessage(nil, canRemember: false),
                          L10n.Companion.allowControlMessage(nil, canRemember: true),
                          "and says the answer is for this connection")

        master.manager.answerAuthorization(request, .alwaysAllow)
        XCTAssertTrue(master.manager.peerMayIssueCommands, "this connection may act")
        XCTAssertTrue(master.manager.alwaysAllowedDevices.ids.isEmpty)
        XCTAssertTrue(master.manager.flightAllowance.deviceIDs.isEmpty)
        _ = try connect(master.manager, id: nil)
        XCTAssertFalse(master.manager.peerMayIssueCommands, "the next one is asked")
    }

    func testAPhoneIdentifiedWithoutANameCanStillBeRemembered() throws {
        let master = makeMaster()
        let gen = try connect(master.manager, id: 7, name: nil)
        master.manager.handleReceivedMessage(command(.revealHiddenItems), generation: gen)
        let request = try XCTUnwrap(master.manager.pendingAuthorization)
        XCTAssertTrue(request.canRemember)
        XCTAssertNotEqual(L10n.Companion.allowControlMessage(nil, canRemember: true),
                          L10n.Companion.allowControlMessage(nil, canRemember: false))
    }

    func testTheFlightAllowanceRule() {
        let flightA = UUID(), flightB = UUID()
        var allowance = CompanionFlightAllowance()
        allowance.allow(7, flightID: nil)
        XCTAssertEqual(allowance.follow(flightID: nil), [], "no flight yet: it waits")
        XCTAssertEqual(allowance.follow(flightID: flightA), [], "the next flight takes it")
        XCTAssertTrue(allowance.allows(7))
        allowance.allow(8, flightID: flightA)
        XCTAssertEqual(allowance.follow(flightID: nil), [7, 8], "it ends with that flight")
        XCTAssertFalse(allowance.allows(7))

        allowance.allow(7, flightID: flightA)
        XCTAssertEqual(allowance.follow(flightID: flightB), [7], "another flight ends it, even with no end seen")
        allowance.allow(9, flightID: flightB)
        allowance.remove([9])
        XCTAssertFalse(allowance.allows(9))
    }

    // MARK: - The link's own rule

    func testTheLinkAsksOnlyOnce() {
        var link = CompanionPeerLink(generation: 1, identity: nil)
        let first = link.admit()
        XCTAssertFalse(first.admitted)
        XCTAssertTrue(first.ask, "the first request asks")
        let second = link.admit()
        XCTAssertFalse(second.admitted)
        XCTAssertFalse(second.ask, "and the next one does not")
        link.authorization = .allowed
        let allowed = link.admit()
        XCTAssertTrue(allowed.admitted)
        XCTAssertFalse(allowed.ask)
        link.authorization = .denied
        let denied = link.admit()
        XCTAssertFalse(denied.admitted)
        XCTAssertFalse(denied.ask)
    }
}
