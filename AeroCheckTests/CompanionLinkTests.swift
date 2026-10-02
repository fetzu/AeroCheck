import XCTest
import CoreLocation
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
        let companion = makeCompanion(role: .master)
        companion.manager.startListening()
        let generation = try XCTUnwrap(companion.manager.adoptMasterConnection(
            identity: CompanionPeerIdentity(deviceID: 7, name: "Pilot's iPhone"), send: sent.handler))
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

        // The iPad answers: back.
        XCTAssertTrue(manager.adoptViewerConnection(identity: CompanionPeerIdentity(deviceID: 3, name: nil),
                                                    generation: manager.connectionGeneration, send: { _ in }))
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: manager.connectionGeneration)
        XCTAssertEqual(manager.connectionState, .connected)
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
        XCTAssertEqual(manager.connectionState, .connected)
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit + 1))
        XCTAssertEqual(manager.connectionState, .connecting)
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

    func testTheLinkEndsAreLoggedAsFixedText() {
        let ends: [CompanionConnectivityManager.LinkEnd] = [.peerLeft, .silence(12), .noFirstFrame, .sendFailing,
                                                            .receiveEnded, .idle(minutes: 10), .forgotten]
        XCTAssertEqual(ends.map(\.text), ["the peer left", "nothing heard for 12 s", "the iPad never answered",
                                          "sends failing", "the connection closed", "idle 10 min with no flight",
                                          "the device was forgotten"])
    }
}
