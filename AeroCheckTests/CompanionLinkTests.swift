import XCTest
import CoreLocation
import UIKit
@testable import AeroCheck

/// The Companion link's own life: how it comes back after the phone leaves, after a drop, after the
/// iPad's idle saving, and what the iPad streams over it.
///
/// The managers here are test ones: their own defaults suite and no Wi-Fi Aware. A listener or a browse
/// "starts" (the role and state are set, `listenerStarts` / `browseStarts` count it) and finds nothing;
/// connections are adopted through the same entry points the real ones use, with a send handler that
/// records what would have gone over the air.
@MainActor
final class CompanionLinkTests: XCTestCase {

    /// What the manager sent, in order. Sends happen on tasks of their own, hence the lock.
    final class SentMessages: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [CompanionMessage] = []

        var all: [CompanionMessage] { lock.withLock { messages } }
        func of(_ type: CompanionMessage.MessageType) -> [CompanionMessage] { all.filter { $0.type == type } }
        func clear() { lock.withLock { messages.removeAll() } }

        var handler: @Sendable (CompanionMessage) async throws -> Void {
            { [self] message in lock.withLock { messages.append(message) } }
        }
    }

    private struct Companion {
        let manager: CompanionConnectivityManager
        let appState: AppState
        /// Held here: the manager keeps its data sources weakly.
        let location: LocationManager
        let plans: FlightPlanManager
    }

    private func makeCompanion(role: CompanionRole) -> Companion {
        let manager = CompanionConnectivityManager(defaults: makeTestDefaults(), usesWiFiAware: false)
        let appState = makeTestAppState()
        appState.settings.enableCompanionMode = true
        let location = LocationManager()
        let plans = makeTestPlanManager()
        manager.configure(appState: appState, locationManager: location, flightPlanManager: plans)
        manager.pairedDevices = [CompanionPairedDevice(name: "Other device", pairingName: nil, deviceIDs: [7])]
        manager.currentRole = role
        addTeardownBlock { @MainActor in
            manager.disconnect()
            if appState.isFlightActive { appState.cancelFlight() }
        }
        return Companion(manager: manager, appState: appState, location: location, plans: plans)
    }

    /// The iPad listening, and the phone's connection taken.
    private func connectedMaster(sent: SentMessages = SentMessages()) throws -> (Companion, Int) {
        try connectedMaster(send: sent.handler)
    }

    private func connectedMaster(send: @escaping @Sendable (CompanionMessage) async throws -> Void) throws -> (Companion, Int) {
        let companion = makeCompanion(role: .master)
        companion.manager.startListening()
        let generation = try XCTUnwrap(companion.manager.adoptMasterConnection(
            identity: CompanionPeerIdentity(deviceID: 7, name: "Pilot's iPhone"), send: send))
        return (companion, generation)
    }

    /// The phone looking for the iPad, and its connection made.
    private func connectedViewer(sent: SentMessages = SentMessages()) throws -> (Companion, Int) {
        let companion = makeCompanion(role: .viewer)
        companion.manager.connectToPairedDevice()
        let generation = companion.manager.connectionGeneration
        XCTAssertTrue(companion.manager.adoptViewerConnection(
            identity: CompanionPeerIdentity(deviceID: 3, name: "Club iPad"), generation: generation, send: sent.handler))
        return (companion, generation)
    }

    private var goodbye: CompanionMessage { CompanionMessage(type: .disconnect, payload: Data()) }

    /// Polls `condition` on the main actor until it holds or `timeout` runs out.
    private func eventually(within timeout: TimeInterval = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - The phone leaves and comes back (6.1.0)

    /// Companion mode off on the phone sends a goodbye. The iPad went "disconnected" on it, with its old
    /// listener still up but never taking the phone's next connection, and only toggling Companion mode
    /// on the iPad brought the phone back.
    func testTheIPadListensAgainWhenThePhoneLeaves() async throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let starts = manager.listenerStarts

        XCTAssertFalse(manager.handleReceivedMessage(goodbye, generation: generation),
                       "the connection that said goodbye is not read any further")
        XCTAssertEqual(manager.connectionState, .connecting, "waiting for the phone, not disconnected")
        XCTAssertEqual(manager.currentRole, .master)
        XCTAssertNil(manager.peerLink)
        XCTAssertNil(manager.connectedDeviceName)

        // The goodbye's connection then closes; its receive loop's teardown comes in late.
        manager.handleDisconnection(generation: generation, reason: .receiveEnded)

        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed, "a fresh listener")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(manager.listenerStarts, starts + 1, "once: the late teardown does not re-arm again")

        // Companion mode back on on the phone: its next connection is taken, nothing touched on the iPad.
        let next = try XCTUnwrap(manager.adoptMasterConnection(identity: CompanionPeerIdentity(deviceID: 7, name: nil),
                                                               send: { _ in }))
        XCTAssertGreaterThan(next, generation)
        XCTAssertEqual(manager.connectionState, .connected)
    }

    /// A drop the iPad notices itself (silence) re-arms once, whatever the dropped connection does after.
    func testADropReArmsTheListenerOnce() async throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let starts = manager.listenerStarts

        manager.checkConnectionHealth(now: Date().addingTimeInterval(60))
        XCTAssertEqual(manager.connectionState, .connecting)
        manager.handleDisconnection(generation: generation, reason: .receiveEnded)
        XCTAssertFalse(manager.handleReceivedMessage(goodbye, generation: generation), "its frames are stale too")

        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(manager.listenerStarts, starts + 1)
        XCTAssertEqual(manager.connectionState, .connecting)
    }

    /// The idle saving (10 min up, no flight) ends the link and tells the phone, but the iPad listens on,
    /// so the phone can come back on its own later. It used to stop listening too.
    func testTheIdleSavingKeepsTheIPadListening() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        let manager = companion.manager
        XCTAssertFalse(companion.appState.isFlightActive)

        manager.checkConnectionHealth(now: Date().addingTimeInterval(-601))   // idle since then
        XCTAssertEqual(manager.connectionState, .connected)
        manager.checkConnectionHealth()
        XCTAssertEqual(manager.connectionState, .connecting, "listening, not disconnected")
        XCTAssertEqual(manager.currentRole, .master)
        let told = try await eventually { !sent.of(.disconnect).isEmpty }
        XCTAssertTrue(told, "the phone is told, so it stops until it is used again")

        let starts = manager.listenerStarts
        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed)
        XCTAssertNotNil(manager.adoptMasterConnection(identity: CompanionPeerIdentity(deviceID: 7, name: nil),
                                                      send: { _ in }),
                        "the phone's next connection is taken")
    }

    func testAFlightKeepsTheLinkUpPastTheIdleTime() throws {
        let (companion, _) = try connectedMaster()
        companion.appState.settings.selectedRemoteAircraftId = nil
        companion.appState.settings.selectedAircraft = .wt9Dynamic
        companion.appState.startFlight()
        XCTAssertTrue(companion.appState.isFlightActive)
        companion.manager.checkConnectionHealth(now: Date().addingTimeInterval(-601))
        companion.manager.checkConnectionHealth()
        XCTAssertEqual(companion.manager.connectionState, .connected)
    }

    // MARK: - A listener that fails is started again (6.1.0)

    func testAFailedListenerIsRetriedNotAbandoned() async throws {
        let companion = makeCompanion(role: .master)
        let manager = companion.manager
        manager.startListening()
        let starts = manager.listenerStarts

        manager.listenerFailed(CocoaError(.featureUnsupported))
        XCTAssertEqual(manager.connectionState, .connecting, "still waiting for a phone: it was left disconnected")
        let retried = try await eventually(within: 4) { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(retried, "another listener after the pause")
    }

    func testARetryPendingWhenTheUserDisconnectsStartsNothing() async throws {
        let companion = makeCompanion(role: .master)
        let manager = companion.manager
        manager.startListening()
        manager.listenerFailed(CocoaError(.featureUnsupported))
        manager.disconnect()
        let starts = manager.listenerStarts

        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(manager.listenerStarts, starts)
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    func testAListenerErrorUnderALiveLinkChangesNothing() throws {
        let (companion, _) = try connectedMaster()
        companion.manager.listenerFailed(CocoaError(.featureUnsupported))
        XCTAssertEqual(companion.manager.connectionState, .connected)
    }

    func testTheListenerRetryBacksOff() {
        let delays = (1...7).map { CompanionConnectivityManager.listenerRetryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30, 30])
    }

    // MARK: - The iPad ends the link (6.1.0)

    func testThePhoneStopsWhenTheIPadEndsTheLink() async throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        let browses = manager.browseStarts

        XCTAssertFalse(manager.handleReceivedMessage(goodbye, generation: generation))
        XCTAssertEqual(manager.connectionState, .disconnected, "the iPad said goodbye: no retry loop")
        manager.handleDisconnection(generation: generation, reason: .receiveEnded)
        XCTAssertEqual(manager.connectionState, .disconnected, "the closed connection's teardown is stale")

        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(manager.browseStarts, browses, "nothing looks for the iPad until the phone is used")
    }

    // MARK: - Riding out a short drop (6.1.0)

    /// Any frame from the iPad, as the phone hears it.
    private var aFrameFromTheIPad: CompanionMessage {
        CompanionMessage(type: .checklistUpdate, payload: Data(#"{"phaseTitle":"Taxi"}"#.utf8))
    }

    /// Two keep-alives lost in a row (5 s) ended the link; the stale banner still comes at 5 s, the
    /// link goes at 10.
    func testASilenceOfAFewSecondsKeepsTheLink() throws {
        let (companion, _) = try connectedMaster()
        let manager = companion.manager
        manager.checkConnectionHealth(now: Date().addingTimeInterval(6))
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertEqual(CompanionTiming.streamStaleAfter, 5, "the banner's window is unchanged")
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .connecting, "ten seconds of silence: the link goes")
    }

    func testAFewFailedSendsDoNotEndTheLink() throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let now = Date()
        // One bad second: the flight data, the checklist and the plan.
        for offset in [0.0, 0.3, 0.9] {
            manager.noteSendFailure(generation: generation, error: CocoaError(.featureUnsupported),
                                    now: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(manager.connectionState, .connected, "three failures in a row ended the link")
        manager.noteSendFailure(generation: generation, error: CocoaError(.featureUnsupported),
                                now: now.addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .connecting, "failing for ten seconds does")
    }

    /// The phone looking for the iPad again after a drop used to read `.connecting`, which the root
    /// shows the phone's ground screen for: it flashed on every short drop.
    func testAShortDropKeepsTheCompanionScreenUp() async throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: generation)
        let browses = manager.browseStarts

        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .reconnecting, "the Companion screen, its banner on")
        XCTAssertEqual(manager.currentRole, .viewer)

        let lookedAgain = try await eventually { manager.browseStarts == browses + 1 }
        XCTAssertTrue(lookedAgain, "looking for the iPad again")
        XCTAssertEqual(manager.connectionState, .reconnecting, "and still on the Companion screen while it does")

        // A connection: not back yet, its banner still on, until the iPad answers.
        XCTAssertTrue(manager.adoptViewerConnection(identity: CompanionPeerIdentity(deviceID: 3, name: nil),
                                                    generation: manager.connectionGeneration, send: { _ in }))
        XCTAssertEqual(manager.connectionState, .reconnecting, "no frame from the iPad yet")
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: manager.connectionGeneration)
        XCTAssertEqual(manager.connectionState, .connected)
    }

    /// The dropped connection is done with: a frame it still delivers does not count for the link.
    func testFramesFromADroppedConnectionNoLongerCount() throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: generation)
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .reconnecting)

        XCTAssertFalse(manager.handleReceivedMessage(aFrameFromTheIPad, generation: generation),
                       "stale: its receive loop stops")
        XCTAssertEqual(manager.connectionState, .reconnecting)
    }

    func testTheCompanionScreenGivesWayAfterTheGrace() {
        let now = Date()
        XCTAssertEqual(CompanionTiming.reconnectGrace, 30)
        XCTAssertEqual(CompanionConnectivityManager.viewerLookingState(linkLostAt: now.addingTimeInterval(-29), now: now),
                       .reconnecting)
        XCTAssertEqual(CompanionConnectivityManager.viewerLookingState(linkLostAt: now.addingTimeInterval(-31), now: now),
                       .connecting, "past the grace: the phone's own screens, still looking")
        XCTAssertEqual(CompanionConnectivityManager.viewerLookingState(linkLostAt: nil, now: now), .connecting,
                       "no drop (a first connection): the phone's own screens")
    }

    /// A connection that never hears from the iPad went to a listener that is gone: given up after 5 s,
    /// and, never having been a link, it does not hold the Companion screen up.
    func testAConnectionTheIPadNeverAnswersIsGivenUpSooner() throws {
        let (companion, _) = try connectedViewer()
        let manager = companion.manager
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit - 1))
        XCTAssertNotNil(manager.peerLink, "still waiting for the iPad")
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit + 1))
        XCTAssertNil(manager.peerLink, "given up")
        XCTAssertEqual(manager.connectionState, .connecting)
        XCTAssertEqual(manager.viewerFailedAttempts, 1)
    }

    // MARK: - Connected only once the iPad answers (6.2.0)

    /// The phone went `.connected` the moment its connection existed, before a word from the iPad: with
    /// a listener that had gone it showed "connected", its data stale, then the link lost, in a loop.
    func testThePhoneIsConnectedOnlyOnceTheIPadAnswers() throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        XCTAssertEqual(manager.connectionState, .connecting, "a connection is no link: the phone's own screens")
        XCTAssertEqual(manager.connectedDeviceName, "Club iPad")

        manager.handleReceivedMessage(aFrameFromTheIPad, generation: generation)
        XCTAssertEqual(manager.connectionState, .connected)
    }

    /// Connections the iPad never answers are tried again later each time, and its first frame ends the
    /// back-off.
    func testConnectionsTheIPadNeverAnswersBackOff() async throws {
        let (companion, _) = try connectedViewer()
        let manager = companion.manager
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit + 1))
        XCTAssertEqual(manager.viewerFailedAttempts, 1)
        let browses = manager.browseStarts
        let first = try await eventually { manager.browseStarts == browses + 1 }
        XCTAssertTrue(first, "the first try again after 2 s")

        // The next connection, never answered either: 4 s this time.
        XCTAssertTrue(manager.adoptViewerConnection(identity: CompanionPeerIdentity(deviceID: 3, name: nil),
                                                    generation: manager.connectionGeneration, send: { _ in }))
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit + 1))
        XCTAssertEqual(manager.viewerFailedAttempts, 2)
        try await Task.sleep(for: .milliseconds(2_600))
        XCTAssertEqual(manager.browseStarts, browses + 1, "not after 2 s again")

        // The iPad answers at last: the back-off is over.
        manager.browseWatchdogFired(generation: -1)   // a stale watchdog changes nothing
        XCTAssertEqual(manager.viewerFailedAttempts, 2)
        let back = try await eventually(within: 3) { manager.browseStarts == browses + 2 }
        XCTAssertTrue(back)
        XCTAssertTrue(manager.adoptViewerConnection(identity: CompanionPeerIdentity(deviceID: 3, name: nil),
                                                    generation: manager.connectionGeneration, send: { _ in }))
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: manager.connectionGeneration)
        XCTAssertEqual(manager.viewerFailedAttempts, 0)
        XCTAssertEqual(manager.connectionState, .connected)
    }

    func testTheViewersRetryBacksOff() {
        let delays = (1...7).map { CompanionConnectivityManager.viewerRetryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 16, 16, 16])
    }

    // MARK: - A browse that finds nothing is started afresh (6.2.0)

    /// Nothing restarted a browse that hung: the phone looked for the iPad for as long as it stayed in
    /// the foreground.
    func testABrowseThatFindsNoIPadIsStartedAfresh() async throws {
        let companion = makeCompanion(role: .viewer)
        let manager = companion.manager
        manager.connectToPairedDevice()
        let browses = manager.browseStarts
        XCTAssertEqual(CompanionTiming.browseWatchdog, 15)

        manager.browseWatchdogFired(generation: manager.connectionGeneration)
        XCTAssertEqual(manager.viewerFailedAttempts, 1)
        XCTAssertEqual(manager.connectionState, .connecting, "still looking")
        let again = try await eventually { manager.browseStarts == browses + 1 }
        XCTAssertTrue(again, "a fresh browse, after the back-off's first pause")
    }

    func testTheWatchdogLeavesAFoundIPadAlone() throws {
        let (companion, generation) = try connectedViewer()
        companion.manager.browseWatchdogFired(generation: generation)
        XCTAssertEqual(companion.manager.viewerFailedAttempts, 0, "a connection is waiting for the iPad's answer")
        XCTAssertNotNil(companion.manager.peerLink)
    }

    /// Looking afresh (back from the background, Forget, Allow Again) while a connection waits for the
    /// iPad's first frame: the connection goes with the browse that made it.
    func testLookingAfreshDropsAConnectionStillWaitingForTheIPad() throws {
        let (companion, _) = try connectedViewer()
        let manager = companion.manager
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertNil(manager.peerLink)
        XCTAssertEqual(manager.connectionState, .connecting)
        manager.browseWatchdogFired(generation: manager.connectionGeneration)
        XCTAssertEqual(manager.viewerFailedAttempts, 1, "the new browse's watchdog is not held back by the old connection")
    }

    func testTheWatchdogStopsWithDisconnect() async throws {
        let companion = makeCompanion(role: .viewer)
        let manager = companion.manager
        manager.connectToPairedDevice()
        let generation = manager.connectionGeneration
        manager.disconnect()
        let browses = manager.browseStarts
        manager.browseWatchdogFired(generation: generation)
        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(manager.browseStarts, browses)
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    // MARK: - A connection that fails is a drop at once (6.2.0)

    func testAConnectionThatFailsIsADropAtOnce() async throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: generation)
        let browses = manager.browseStarts

        manager.connectionStatusChanged(.ready, generation: generation)
        manager.connectionStatusChanged(.preparing, generation: generation)
        XCTAssertEqual(manager.connectionState, .connected, "ready or preparing changes nothing")

        manager.connectionStatusChanged(.failed("Network.NWError 1"), generation: generation)
        XCTAssertEqual(manager.connectionState, .reconnecting, "not after ten seconds of silence")
        XCTAssertNil(manager.peerLink)
        let lookedAgain = try await eventually { manager.browseStarts == browses + 1 }
        XCTAssertTrue(lookedAgain)

        manager.connectionStatusChanged(.failed("Network.NWError 1"), generation: generation)
        XCTAssertEqual(manager.connectionState, .reconnecting, "the old connection's states are stale")
    }

    /// A connection waiting for its path (being set up, or coming back) is no drop: one that never comes back
    /// ends by its silence. A failed one is a drop on the iPad too.
    func testAConnectionWaitingIsNoDropAndAFailedOneIsOnTheIPadToo() async throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let starts = manager.listenerStarts
        manager.connectionStatusChanged(.waiting("Network.NWError 50"), generation: generation)
        XCTAssertEqual(manager.connectionState, .connected, "waiting for its path is no drop")
        XCTAssertNotNil(manager.peerLink)
        manager.connectionStatusChanged(.failed("Network.NWError 57"), generation: generation)
        XCTAssertEqual(manager.connectionState, .connecting, "listening for the phone again")
        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed)
    }

    // MARK: - Sends that hang (6.2.0)

    func testASendThatHangsIsGivenUp() async {
        let cancelled = SentFlag()
        let hangs: @Sendable (CompanionMessage) async throws -> Void = { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set(); throw error }
        }
        let start = ContinuousClock.now
        do {
            try await CompanionConnectivityManager.send(goodbye, on: hangs, within: .milliseconds(300))
            XCTFail("a send that hangs does not go")
        } catch {
            XCTAssertTrue(error is CompanionSendTimeout)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let stopped = try? await eventually { cancelled.isSet }
        XCTAssertEqual(stopped, true, "and the send itself is called off")
    }

    final class Sentinel: @unchecked Sendable {}

    /// A send waiting on a connection kept the outbox, its send handler, and with it the connection,
    /// alive after the link had gone: one more on each reconnection.
    func testAConnectionGoneIsNotKeptAliveByItsOutbox() async throws {
        weak var held: Sentinel?
        let generation: Int
        let manager: CompanionConnectivityManager
        do {
            let connection = Sentinel()
            held = connection
            let hangs: @Sendable (CompanionMessage) async throws -> Void = { _ in
                _ = connection
                try await Task.sleep(for: .seconds(60))
            }
            let (companion, gen) = try connectedMaster(send: hangs)
            manager = companion.manager
            generation = gen
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(held, "the stream's first send is under way")

        manager.handleDisconnection(generation: generation, reason: .silence(11))
        let released = try await eventually(within: 4) { held == nil }
        XCTAssertTrue(released, "the outbox ends with its connection")
    }

    // MARK: - Data stale by the phone's own clock (6.2.0)

    private func flightData(sentAt timestamp: Date) -> CompanionFlightData {
        CompanionFlightData(isFlightActive: true, currentPhase: "CRUISE", currentPhaseRawValue: 9, isCircuitMode: false,
                            engineStartTime: nil, lineUpTime: nil, landingTime: nil, alwaysUseUTC: false,
                            latitude: 47.2, longitude: 7.0, speedMPS: 51, altitudeFeet: 4_500, courseDegrees: 230,
                            gpsSignalStatus: "good", ownGPSAvailable: true, gpsSource: "own", cockpitThemeMode: "day",
                            currentWaypointIndex: 0, chronometerStartTime: nil, chronometerElapsed: 0,
                            aircraftRegistration: "F-HVXA", aircraftType: "WT9 Dynamic", timestamp: timestamp)
    }

    /// The banner compared the phone's clock with the iPad's timestamp: a few seconds between the two
    /// clocks made it come and go on a link that was fine.
    func testDataIsStaleByWhenItArrivedNotByTheIPadsClock() throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        for skew in [-8.0, 8.0] {   // the iPad's clock behind, then ahead
            let frame = CompanionMessage(type: .flightData,
                                         payload: try JSONEncoder().encode(flightData(sentAt: Date().addingTimeInterval(skew))))
            manager.handleReceivedMessage(frame, generation: generation)
            let arrived = try XCTUnwrap(manager.lastReceivedDataAt)
            XCTAssertEqual(arrived.timeIntervalSinceNow, 0, accuracy: 1, "this phone's clock")
            XCTAssertFalse(CompanionConnectivityManager.flightDataIsStale(receivedAt: arrived, now: Date()),
                           "just arrived: fresh, whatever the iPad's clock says")
            XCTAssertTrue(CompanionConnectivityManager.flightDataIsStale(
                receivedAt: arrived, now: arrived.addingTimeInterval(CompanionTiming.streamStaleAfter + 1)))
        }
        manager.disconnect()
        XCTAssertNil(manager.lastReceivedDataAt)
    }

    // MARK: - The iPad streams while its screen tracks a touch (6.2.0)

    /// A scroll or a drag runs the main run loop in its tracking mode, where a timer of the default mode
    /// does not fire: a long gesture on the iPad left the phone "data stale", then "connection lost".
    func testTheIPadStreamsWhileItsScreenTracksATouch() throws {
        let (companion, _) = try connectedMaster()
        let manager = companion.manager
        let ticks = manager.streamTicks
        let end = Date().addingTimeInterval(2.5)
        while Date() < end {
            _ = RunLoop.main.run(mode: .tracking, before: end)
        }
        XCTAssertGreaterThanOrEqual(manager.streamTicks, ticks + 2, "the 1 Hz stream went on")
    }

    // MARK: - The phone's screen stays on while it shows the iPad's flight (6.2.0)

    func testThePhoneKeepsItsScreenOnWhileItShowsTheIPadsFlight() {
        func awake(_ flight: Bool, _ role: CompanionRole, _ state: CompanionConnectionState) -> Bool {
            ScreenAwakeRule.keepsAwake(isFlightActive: flight, companionRole: role, companionState: state)
        }
        XCTAssertTrue(awake(true, .none, .disconnected), "a flight, as ever")
        XCTAssertTrue(awake(true, .master, .connected))
        XCTAssertFalse(awake(false, .none, .disconnected), "on the desk it locks")
        XCTAssertFalse(awake(false, .master, .connected), "an iPad with no flight locks, phone or not")
        XCTAssertTrue(awake(false, .viewer, .connected), "the phone showing the iPad's flight")
        XCTAssertTrue(awake(false, .viewer, .reconnecting), "and while it rides out a drop")
        XCTAssertFalse(awake(false, .viewer, .connecting), "on its own screens, looking")
        XCTAssertFalse(awake(false, .viewer, .disconnected))
    }

    // MARK: - Datagram sizes in the log (6.2.0)

    /// A message over the connection's datagram size goes in fragments: logged once per type and
    /// connection, sizes only.
    func testAMessageOverTheDatagramSizeIsLoggedOnceWithSizesOnly() throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        manager.noteMaximumDatagramSize(200, generation: generation)
        XCTAssertTrue(manager.diagnostics.contains { $0.contains("datagrams up to 200 bytes") })

        manager.streamTick(now: Date().addingTimeInterval(100))
        manager.streamTick(now: Date().addingTimeInterval(110))
        let over = manager.diagnostics.filter { $0.contains("a flightData of") }
        XCTAssertEqual(over.count, 1, "once")
        let line = try XCTUnwrap(over.first)
        XCTAssertTrue(line.contains("over the 200-byte datagram"), line)
        XCTAssertFalse(line.contains("Pilot"), "never a device name")

        manager.noteMaximumDatagramSize(100_000, generation: generation - 1)
        XCTAssertFalse(manager.diagnostics.contains { $0.contains("100000") }, "a connection gone says nothing")
    }

    // MARK: - Back from the background (6.1.0)

    func testBackFromTheBackgroundTheIPadListensAfresh() {
        let companion = makeCompanion(role: .master)
        let manager = companion.manager
        manager.startListening()
        let starts = manager.listenerStarts

        manager.appBecameActive()
        XCTAssertEqual(manager.listenerStarts, starts, "a system sheet gone: nothing restarted")
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertEqual(manager.listenerStarts, starts + 1, "a listener left over a suspension is started afresh")
        XCTAssertEqual(manager.connectionState, .connecting)
    }

    func testBackFromTheBackgroundThePhoneLooksAfresh() {
        let companion = makeCompanion(role: .viewer)
        let manager = companion.manager
        manager.connectToPairedDevice()
        let browses = manager.browseStarts
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertEqual(manager.browseStarts, browses + 1)
    }

    func testBackInTheForegroundWithNothingRunningAutoConnects() {
        // How a phone the iPad said goodbye to comes back: when it is used.
        let companion = makeCompanion(role: .viewer)
        let manager = companion.manager
        XCTAssertEqual(manager.connectionState, .disconnected)
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertNotEqual(manager.connectionState, .disconnected, "auto-connect started a listener or a browse")
    }

    // MARK: - The plan reaches the phone (6.1.0)

    /// LSZQ → LSZB at 5,000 ft and 100 kt, leaving in an hour: ETOs to anchor.
    private func armedPlan(on plans: FlightPlanManager) -> FlightPlan {
        var plan = FlightPlan(name: "LSZQ → LSZB", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
            FlightPlanWaypoint(name: "LSZB", coordinate: .init(latitude: 46.914, longitude: 7.497)),
        ])
        plan.plannedDepartureTime = Date().addingTimeInterval(3_600)
        for i in plan.waypoints.indices {
            plan.waypoints[i].altitude = 5_000
            plan.waypoints[i].plannedGroundSpeed = 100
        }
        plan.calculateRouteData()
        plans.add(plan)
        plans.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in plans.stopChronometer() }
        return plan
    }

    /// The last plan the phone was sent, decoded as the phone decodes it.
    private func lastPlan(_ sent: SentMessages) throws -> CompanionFlightPlanSnapshot? {
        try sent.of(.flightPlanUpdate).last.map {
            try JSONDecoder().decode(CompanionFlightPlanSnapshot.self, from: $0.payload)
        }
    }

    /// READY FOR LINE UP anchors the ETOs on the iPad. The phone showed --:-- until a reconnect sent it
    /// the whole plan again: the iPad resent the plan only for a new plan, a diversion, or once a
    /// waypoint had a time over.
    func testETOsAnchoredBeforeTheTakeoffReachThePhoneOnTheNextTick() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        let plan = armedPlan(on: companion.plans)
        let now = Date()
        companion.manager.streamTick(now: now)
        let first = try await eventually { !sent.of(.flightPlanUpdate).isEmpty }
        XCTAssertTrue(first)

        let lineUp = now.addingTimeInterval(120)
        companion.plans.anchorETOsOnLineUp(lineUp)
        let anchored = try XCTUnwrap(companion.plans.activeFlightPlan?.waypoints.last?.estimatedTimeOver)
        XCTAssertNotEqual(anchored, plan.waypoints.last?.estimatedTimeOver, "the anchor moved the ETOs")
        XCTAssertNil(companion.plans.activeFlightPlan?.waypoints.first { $0.actualTimeOver != nil },
                     "no time over yet: what kept the old check from sending")

        companion.manager.streamTick(now: now.addingTimeInterval(1))
        let arrived = try await eventually { (try? self.lastPlan(sent))??.waypoints.last?.estimatedTimeOver == anchored }
        XCTAssertTrue(arrived, "the anchored ETO goes on the next tick")
    }

    func testATimeOverTakenBackReachesThePhone() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        _ = armedPlan(on: companion.plans)
        var now = Date()
        companion.manager.streamTick(now: now)

        var marked = try XCTUnwrap(companion.plans.activeFlightPlan)
        marked.waypoints[0].actualTimeOver = now
        companion.plans.updateFlightPlan(marked)
        now += 1
        companion.manager.streamTick(now: now)
        let markSent = try await eventually { (try? self.lastPlan(sent))??.waypoints.first?.actualTimeOver != nil }
        XCTAssertTrue(markSent)

        // UNDO: no time over left anywhere, which the old check took for "nothing to send".
        var undone = marked
        undone.waypoints[0].actualTimeOver = nil
        companion.plans.updateFlightPlan(undone)
        now += 1
        companion.manager.streamTick(now: now)
        let undoSent = try await eventually {
            let plan = (try? self.lastPlan(sent)) ?? nil
            return plan != nil && plan?.waypoints.first?.actualTimeOver == nil
        }
        XCTAssertTrue(undoSent, "the phone sees the time over go")
    }

    func testAnUnchangedPlanIsSentAgainEveryFewSeconds() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        _ = armedPlan(on: companion.plans)
        let now = Date().addingTimeInterval(100)   // ahead of the stream's own timer
        companion.manager.streamTick(now: now)
        let first = try await eventually { sent.of(.flightPlanUpdate).count == 1 }
        XCTAssertTrue(first)

        companion.manager.streamTick(now: now.addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent.of(.flightPlanUpdate).count, 1, "unchanged and not due: not sent")

        companion.manager.streamTick(now: now.addingTimeInterval(CompanionTiming.snapshotRefresh))
        let again = try await eventually { sent.of(.flightPlanUpdate).count == 2 }
        XCTAssertTrue(again, "due again: a datagram lost over UDP is not resent otherwise")
    }

    func testPlanSnapshotsDifferOnTheirTimes() {
        func snapshot(eto: Date?, ato: Date?) -> CompanionFlightPlanSnapshot {
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let wp = CompanionWaypoint(id: id, name: "LSZB", latitude: 46.9, longitude: 7.5, altitude: 1_700,
                                       frequency: nil, magneticCourse: 140, distance: 22, plannedGroundSpeed: 100,
                                       estimatedElapsedTime: 800, legEETExtra: nil, cumulativeEET: 800,
                                       estimatedTimeOver: eto, actualTimeOver: ato, remarks: "")
            return CompanionFlightPlanSnapshot(planId: id, planName: "Plan", waypoints: [wp], currentWaypointIndex: 0,
                                               totalDistance: 22, totalEET: 800, plannedDepartureTime: nil,
                                               chronometerStartTime: nil)
        }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(snapshot(eto: t, ato: nil), snapshot(eto: t, ato: nil))
        XCTAssertNotEqual(snapshot(eto: nil, ato: nil), snapshot(eto: t, ato: nil), "an ETO is a change")
        XCTAssertNotEqual(snapshot(eto: t, ato: nil), snapshot(eto: t.addingTimeInterval(60), ato: nil))
        XCTAssertNotEqual(snapshot(eto: t, ato: t), snapshot(eto: t, ato: nil), "so is a time over taken back")
    }

    // MARK: - The NAV screen's figures reach the phone (6.2.0)

    /// The last flight data the phone was sent, decoded as the phone decodes it.
    private func lastFlightData(_ sent: SentMessages) throws -> CompanionFlightData? {
        try sent.of(.flightData).last.map {
            try JSONDecoder().decode(CompanionFlightData.self, from: $0.payload)
        }
    }

    /// The Cockpit's radio in the Jura, 15 NM from Les Eplatures: the area's Info NOW, the field NEXT.
    private func juraRadio() -> CockpitRadio {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        let lsgc = CLLocationCoordinate2D(latitude: 47.0839, longitude: 6.7928)
        let sources = PhaseFrequencyPlanner.Sources(
            hasAirportData: true,
            nearestFields: { _ in [PhaseFrequencyPlanner.Field(ident: "LSGC", coordinate: lsgc)] },
            fieldFrequencies: { $0 == "LSGC" ? [(type: "AFIS", frequency: "120.155")] : [] },
            nearbyCTRs: { _ in [] })
        radio.update(position: CLLocationCoordinate2D(latitude: 47.05, longitude: 7.15), plan: nil, sources: sources)
        return radio
    }

    /// NOW and NEXT go with the flight data from the Cockpit's radio, the one source on the iPad, and the
    /// phone's NOW line shows them. With no Cockpit on screen (the flight over), neither goes, and the
    /// phone falls back on its FREQ, as with an older iPad.
    func testThePhoneGetsTheCockpitsNowAndNext() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        let radio = juraRadio()
        let now = try XCTUnwrap(radio.now)
        let next = try XCTUnwrap(radio.next)
        companion.manager.cockpitRadio = radio

        sent.clear()
        companion.manager.streamTick(now: Date().addingTimeInterval(100))
        let arrived = try await eventually { (try? self.lastFlightData(sent))??.nowFrequency != nil }
        XCTAssertTrue(arrived)
        let data = try XCTUnwrap(try lastFlightData(sent))
        XCTAssertEqual(data.nowFrequency, CompanionFrequency(station: now.station, frequency: now.freq))
        XCTAssertEqual(data.nextFrequency, CompanionFrequency(station: next.station, frequency: next.freq))
        XCTAssertEqual(CompanionNowLine.make(flightData: data, plan: nil),
                       .radio(now: data.nowFrequency, next: data.nextFrequency))
        XCTAssertEqual(CompanionRadio.stations(flightData: data, plan: nil).map(\.freq), [now.freq, next.freq])

        companion.manager.cockpitRadio = nil
        sent.clear()
        companion.manager.streamTick(now: Date().addingTimeInterval(101))
        let gone = try await eventually { (try? self.lastFlightData(sent)) != nil }
        XCTAssertTrue(gone)
        let without = try XCTUnwrap(try lastFlightData(sent))
        XCTAssertNil(without.nowFrequency)
        XCTAssertNil(without.nextFrequency)
        XCTAssertEqual(CompanionNowLine.make(flightData: without, plan: nil), .freq(station: "GUARD", frequency: "121.50"))
    }

    /// The phone's DEST line, from the plan and the position the iPad streams, is the iPad's own: the same
    /// distance, ETE, ETA and Δ, the same track.
    func testThePhonesDestLineIsTheIPads() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        _ = armedPlan(on: companion.plans)
        companion.plans.recordATO(forWaypointAt: 0)
        // Half way, at 100 kt on the course.
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 47.15, longitude: 7.26), altitude: 1_500,
                             horizontalAccuracy: 5, verticalAccuracy: 5, course: 146, speed: 51.44, timestamp: Date())
        companion.location.currentLocation = fix

        sent.clear()
        companion.manager.streamTick(now: Date().addingTimeInterval(200))
        let both = try await eventually { !sent.of(.flightPlanUpdate).isEmpty && !sent.of(.flightData).isEmpty }
        XCTAssertTrue(both)
        let snapshot = try XCTUnwrap(try lastPlan(sent))
        let data = try XCTUnwrap(try lastFlightData(sent))
        XCTAssertEqual(data.currentWaypointIndex, 1)

        let now = Date()
        let phone = try XCTUnwrap(DestinationEstimator.estimate(DestinationInput(snapshot: snapshot, flightData: data, now: now)))
        let iPad = try XCTUnwrap(DestinationEstimator.estimate(DestinationInput(
            plan: try XCTUnwrap(companion.plans.activeFlightPlan), location: fix,
            groundSpeedKnots: try XCTUnwrap(data.speedMPS) * CompanionNav.knotsPerMetrePerSecond, now: now)))
        assertSameDestination(phone, iPad)
        XCTAssertEqual(phone.kind, .route)
        XCTAssertEqual(phone.ident, "LSZB")
        XCTAssertNotNil(phone.eta, "timed at 100 kt")
        XCTAssertNotNil(phone.track)
    }

    // MARK: - The checklist reaches the phone (6.1.0)

    /// The last checklist the phone was sent, decoded as the phone decodes it.
    private func lastChecklist(_ sent: SentMessages) throws -> CompanionChecklistSnapshot? {
        try sent.of(.checklistUpdate).last.map {
            try JSONDecoder().decode(CompanionChecklistSnapshot.self, from: $0.payload)
        }
    }

    /// A flight on the WT9 with the Memory test on: its TAXI is a memory check, the check before it a list.
    private func memoryTestFlight(_ appState: AppState) throws {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = false
        appState.settings.stepByStepHighlighting = true
        appState.startFlight()
        try XCTSkipUnless(appState.isMemoryCheck(.taxi), "needs the WT9's memory checks")
        XCTAssertFalse(appState.isMemoryCheck(.afterEngineStart))
    }

    /// The check slot rides in the checklist snapshot as JSON, and JSONEncoder's key order changes from
    /// one encode to the next: every snapshot in flight differed from the last, so the "only when it
    /// changed" check never held there. Sorted keys, the same bytes.
    func testTheCheckSlotEncodesTheSameEveryTime() throws {
        let companion = makeCompanion(role: .master)
        try memoryTestFlight(companion.appState)
        companion.appState.currentPhase = .taxi
        let snapshots = (0..<20).map { _ in
            CompanionConnectivityManager.checklistSnapshot(of: companion.appState, mayStreamItemText: true)
        }
        XCTAssertNotNil(snapshots[0].checkSlotData)
        XCTAssertTrue(snapshots.allSatisfy { $0 == snapshots[0] })
    }

    /// The state goes at once when the phone connects, through the stream itself.
    func testThePhoneGetsTheStateTheMomentItConnects() async throws {
        let sent = SentMessages()
        _ = try connectedMaster(sent: sent)
        let both = try await eventually { !sent.of(.checklistUpdate).isEmpty && !sent.of(.flightData).isEmpty }
        XCTAssertTrue(both, "no tick needed")
    }

    /// The first memory check after the start showed on the phone as a list to tick. Likely: the phone
    /// still had the check before it, the update that moved on lost on the way, and an unchanged
    /// checklist was never sent again. It now is, every few seconds.
    func testAMemoryCheckReachesThePhoneEvenWhenItsFirstUpdateIsLost() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        try memoryTestFlight(companion.appState)
        let now = Date().addingTimeInterval(100)   // ahead of the stream's own timer
        companion.appState.currentPhase = .afterEngineStart
        companion.manager.streamTick(now: now)

        companion.appState.currentPhase = .taxi
        companion.manager.streamTick(now: now.addingTimeInterval(1))
        let moved = try await eventually { (try? self.lastChecklist(sent))??.memoryCheck == true }
        XCTAssertTrue(moved, "the move goes on the tick after it")
        sent.clear()   // ... and is lost on the way

        companion.manager.streamTick(now: now.addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sent.of(.checklistUpdate).isEmpty, "unchanged: not every second")

        companion.manager.streamTick(now: now.addingTimeInterval(1 + CompanionTiming.snapshotRefresh))
        let healed = try await eventually { (try? self.lastChecklist(sent)) != nil }
        XCTAssertTrue(healed, "sent again")
        let checklist = try XCTUnwrap(try lastChecklist(sent))
        XCTAssertEqual(checklist.phaseRawValue, ChecklistPhase.taxi.rawValue)
        XCTAssertTrue(checklist.memoryCheck, "a memory check, which the phone confirms with ✓ DONE")
        XCTAssertTrue(checklist.supportsMemoryConfirm)
        XCTAssertFalse(checklist.memoryCheckDone)
        XCTAssertTrue(checklist.items.isEmpty, "nothing to tick")
    }

    func testTheLinkEndsAreLoggedAsFixedText() {
        let ends: [CompanionConnectivityManager.LinkEnd] = [.peerLeft, .silence(12), .noFirstFrame, .sendFailing,
                                                            .receiveEnded, .idle(minutes: 10), .forgotten,
                                                            .connectionFailed]
        XCTAssertEqual(ends.map(\.text), ["the peer left", "nothing heard for 12 s", "the iPad never answered",
                                          "sends failing", "the connection closed", "idle 10 min with no flight",
                                          "the device was forgotten", "the connection failed"])
    }

    // MARK: - A listener restart waits for the old one (6.1.0)

    func testARestartWaitsForTheOldListenerToEnd() async {
        let quick = Task<Void, any Error> { try await Task.sleep(for: .milliseconds(200)) }
        let start = ContinuousClock.now
        let ended = await CompanionConnectivityManager.waitForEnd(of: quick, upTo: .seconds(3))
        XCTAssertTrue(ended)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "no longer than the old listener takes")
    }

    func testARestartDoesNotWaitForeverForAListenerThatHangs() async {
        let hung = Task<Void, any Error> { try? await Task.sleep(for: .seconds(60)) }
        defer { hung.cancel() }
        let start = ContinuousClock.now
        let ended = await CompanionConnectivityManager.waitForEnd(of: hung, upTo: .milliseconds(500))
        XCTAssertFalse(ended)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the limit holds")
    }

    // MARK: - The phone's goodbye reaches the iPad (6.1.0)

    func testThePhonesGoodbyeGoesOutBeforeItsConnectionCloses() async {
        let connection = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        let sent = SentMessages()
        let closedBeforeTheGoodbye = SentFlag()
        let send: @Sendable (CompanionMessage) async throws -> Void = { message in
            if connection.isCancelled { closedBeforeTheGoodbye.set() }
            try await Task.sleep(for: .milliseconds(50))   // a send takes a moment on the radio
            try await sent.handler(message)
        }
        let went = await CompanionConnectivityManager.sayGoodbye(goodbye, on: send, thenClose: connection,
                                                                 upTo: .seconds(2))
        XCTAssertTrue(went)
        XCTAssertEqual(sent.of(.disconnect).count, 1, "the iPad is told")
        XCTAssertFalse(closedBeforeTheGoodbye.isSet, "the connection was still open when the goodbye left")
        XCTAssertTrue(connection.isCancelled, "and closed after it")
    }

    func testAGoodbyeThatHangsDoesNotKeepTheConnectionOpen() async {
        let connection = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        let hangs: @Sendable (CompanionMessage) async throws -> Void = { _ in try? await Task.sleep(for: .seconds(30)) }
        let start = ContinuousClock.now
        let went = await CompanionConnectivityManager.sayGoodbye(goodbye, on: hangs, thenClose: connection,
                                                                 upTo: .milliseconds(300))
        XCTAssertFalse(went)
        XCTAssertTrue(connection.isCancelled, "closed anyway")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testAPhoneThatDisconnectsTellsTheIPad() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedViewer(sent: sent)
        companion.manager.disconnect()
        let told = try await eventually { !sent.of(.disconnect).isEmpty }
        XCTAssertTrue(told)
    }

    final class SentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
